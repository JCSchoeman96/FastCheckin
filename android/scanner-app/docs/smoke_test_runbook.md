# Android Smoke Test Runbook

This runbook is the acceptance gate for the post-E1 Android tranche.

It is intentionally runtime-focused. Unit tests, migration tests, and build
target checks already prove local correctness. This document covers the
remaining field verification on actual Android runtime surfaces.

## Scope

Validate only the active Android contract:

- `POST /api/v1/mobile/login`
- `GET /api/v1/mobile/attendees`
- `POST /api/v1/mobile/scans`

Do not expand this runbook into future device-session routes, hardware adapters,
or new background orchestration.

## Preconditions

- Phoenix backend is reachable for the target environment.
- Backend runtime is confirmed to be the promoted hot path for Android.
- For Gradle connected tests on Linux, prefer the stable `android-36` emulator
  harness under `android/scanner-app/scripts/run-connected-android-tests.sh`.
  Do not use preview AVDs such as `36.1` for `connectedDebugAndroidTest`.
- Test event exists with:
  - valid mobile login credential
  - at least one valid attendee/ticket
  - at least one ticket that can produce a duplicate result
  - if possible, at least one ticket that can produce `payment_invalid`
- Android app build includes the current post-E1 changes:
  - additive optional `reason_code`
  - diagnostics base-URL visibility
  - Room migration `2 -> 3`

## Target Selection

The app now resolves API target from Gradle properties instead of source edits.

Supported targets:

- `release`
- `emulator`
- `dev`
- `device`

Release notes:

- normal release flow uses the fixed production URL
- `FASTCHECK_API_BASE_URL_RELEASE` is exceptional-only if used
- emulator cleartext support is debug-only and limited to `10.0.2.2`

Example build commands:

```powershell
.\gradlew.bat :app:assembleDebug -PFASTCHECK_API_TARGET=release
.\gradlew.bat :app:assembleDebug -PFASTCHECK_API_TARGET=emulator
.\gradlew.bat :app:assembleDebug -PFASTCHECK_API_TARGET=dev -PFASTCHECK_API_BASE_URL_DEV=https://dev.example.com/
.\gradlew.bat :app:assembleDebug -PFASTCHECK_API_TARGET=device -PFASTCHECK_API_BASE_URL_DEVICE=https://device.example.com/
```

Expected rule:

- no source edits are required to switch targets
- diagnostics and logs must show the same resolved base URL used by Retrofit

### Connected-test harness

For instrumentation classes that should run through Gradle connected tests, use:

```bash
cd android/scanner-app
./scripts/run-connected-android-tests.sh \
  --class za.co.voelgoed.fastcheck.app.MainActivityCameraRecoveryFlowTest
```

This script:

- creates the stable `Medium_Phone_API_36` AVD if missing
- boots it headless with software rendering
- waits for Android boot completion
- runs `:app:connectedDebugAndroidTest --no-daemon`

### Scripted integration harness

For deterministic cross-stack validation (backend boot, seed, mutate, re-sync,
assert), use the dedicated harness runbook in
`docs/mobile_integration_harness.md` and runner script:

```bash
bash scripts/integration/run-mobile-integration-harness.sh
```

Use this smoke runbook for operator/runtime manual checks; use the integration
harness for scripted lifecycle regression coverage.

## Test Matrix

Run the applicable rows for the environments you actually ship or support:

| Surface | `release` | `emulator` | `dev` | `device` |
| --- | --- | --- | --- | --- |
| Compile/build | required | required | required if used | required if used |
| Login | required | required | required if used | required if used |
| Attendee sync | required | required | required if used | required if used |
| Valid scan upload | required | required | required if used | required if used |
| Duplicate/replay-safe outcome | required | required | required if used | required if used |
| Payment-invalid or generic rejection | recommended | recommended | recommended | recommended |
| Camera stop/start + resume | required | required | required if used | required if used |
| Existing upgraded DB opens cleanly | required | required | required if used | required if used |

## Smoke Procedure

### 1. Install and launch

- Install the debug build for the chosen target.
- Launch the app fresh.
- Open Diagnostics immediately.

Verify:

- `API Target` matches the intended target.
- `Resolved Base URL` matches the expected backend URL for that target.
- app logs show the same target/base URL pair on startup.

### 2. Existing DB upgrade safety

Run this at least once on a device or emulator that already has a version-2 app
database.

Verify:

- app starts without database crash
- diagnostics screen loads
- existing queue/flush-related surfaces still render
- previously persisted replay cache / flush outcome state, if present, does not
  disappear due to destructive migration

### 3. Login

- Enter `event_id` and credential.
- Tap login.

Verify:

- login succeeds
- session summary appears
- auth state becomes authenticated
- no unexpected target or base-URL drift appears in diagnostics

### 4. Attendee sync

- Run attendee sync once after login.

Verify:

- sync succeeds
- attendee count updates
- last sync time updates
- no auth or routing errors occur

### 5. Valid scan upload

- Scan or manually queue one known-valid ticket.
- Allow auto-flush or run manual flush.

Verify:

- local queue admission happens first
- upload completes successfully
- diagnostics show a confirmed server result
- app does not imply that local capture alone equals backend acceptance

### 6. Duplicate and replay-safe result

Exercise at least one duplicate scenario.

Preferred cases:

- final replay duplicate with backend `reason_code = replay_duplicate`
- business duplicate with backend `reason_code = business_duplicate`

Verify:

- Android still keys runtime behavior off `status`
- `reason_code` only refines diagnostics wording
- final replay duplicate is shown as `Replay duplicate (final)` only when
  `reason_code` is actually present
- missing `reason_code` remains acceptable and is shown as a generic duplicate
- app does not invent replay certainty from message text

### 7. Payment-invalid or generic rejection

If a payment-invalid ticket is available:

- queue/upload that ticket

Verify:

- terminal result remains driven by `status = error`
- diagnostics refine wording to `Payment invalid` only when
  `reason_code = payment_invalid`
- otherwise, terminal errors stay generic `Rejected`
- app never parses message text into a structured cause

### 8. Camera lifecycle calmness

With a logged-in app and working camera preview:

- grant permission and confirm preview appears
- background the app and resume it
- rotate or recreate activity if part of your supported runtime behavior
- leave and return to the foreground
- deny permission and re-open if needed

Verify:

- preview starts only when permission is granted
- preview hides cleanly when permission is absent or app stops
- resume/start does not produce duplicate bindings or noisy errors
- stop/start remains calm and recoverable

## Pass Criteria

This tranche is accepted only if all required checks pass and the following stay
true in runtime:

- `status` remains the primary decision field
- `reason_code` is optional and additive
- missing `reason_code` is normal
- no message parsing is used to infer truth
- diagnostics wording only reflects proven backend truth
- target selection is explicit and visible
- existing installed DB upgrades cleanly

## Fail Conditions

Treat any of the following as a failed smoke pass:

- diagnostics base URL does not match the intended target
- app requires source edits to switch environments
- existing installed DB is dropped or fails to open
- duplicate/rejection wording is inferred from `message`
- `reason_code` changes queue retention/removal behavior
- camera resume/start creates duplicate binding behavior or unstable preview
- app routes outside `/api/v1/mobile/*`

## Follow-up Recording

If any smoke step fails:

- capture target, build command, device/emulator details, and backend URL
- record the failing step and expected vs actual behavior
- create or update a Beads item immediately

## Scanner Runtime Reliability Pass (Plan `mlkit-camerax-audit_ad12c701`)

Use this focused pass after PR-1 through PR-5:

- Confirm scan screen shows:
  - active event identity
  - synced attendee count
  - last sync value
- Confirm scanner telemetry boundaries in logs:
  - activation evaluated
  - bind requested/success (or stale skipped)
  - decode diagnostics
  - handoff decision
  - admit decision

### Required plain-text test codes

Known plain-text ticket set for runtime validation:

- `99984-2`
- `99998-1`
- `99982-1`
- `99984-1`
- `99941-1`

Run at least:

1. one known-valid code -> accepted
2. immediate repeat of same code -> cooldown suppression
3. one known-invalid or not-found code -> rejected
4. one refunded/payment-blocked code from the same event dataset -> rejected (must not accept)
5. leave Scan -> Event/Support -> Scan -> valid code still decodes and admits
6. app background/resume -> valid code still decodes and admits

Pass gate for this slice:

- no silent decode-dead state while preview is visible
- scanner outcomes remain distinct (`accepted` vs `invalid` vs `cooldown`)
- refunded/payment-blocked tickets are never admitted
