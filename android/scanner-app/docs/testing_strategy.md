# Testing Strategy

## Unit Tests

Required unit coverage:

- DTO to Room entity mapping
- Room entity to domain model mapping
- Room DAO behavior
- queued scan idempotency handling
- worker flush orchestration
- analyzer boundary proving no direct network path
- runtime `IN` direction exposure

### B1 — truthful queue/flush UI projection (post-B1)

Required focused coverage for the truth-modeling slice:

- **Queued locally without flush result**: queue depth shown; server result hidden/neutral.
- **Uploading while queue still exists**: upload state shows Uploading; queue depth remains repository-derived.
- **Retry pending**: retry metadata present; upload state shows Retry pending with attempt.
- **Auth expired**: reflected in upload state.
- **Server result shown only from persisted/classified outcomes** (no message parsing for terminal error precision).

## Hilt Tests

Hilt runtime wiring requires Hilt test setup in the same scaffold pass.

Instrumentation tests should use:

- `HiltTestRunner`
- `@HiltAndroidTest`
- `@TestInstallIn` or `@UninstallModules` to replace production bindings

Replacement targets to document and support:

- repositories
- Room-backed collaborators when needed
- worker-facing use cases
- scanner-boundary collaborators

## Connected Android Tests

Use the stable connected-test harness under:

- `android/scanner-app/scripts/run-connected-android-tests.sh`

This script standardizes the local emulator flow that Gradle connected tests
should use:

- stable `android-36` Google APIs x86_64 system image
- AVD name `Medium_Phone_API_36`
- headless boot with software rendering
- preview AVDs avoided for connected tests

Do not use preview emulator targets such as `36.1` for
`connectedDebugAndroidTest`. They may boot, but Gradle device detection can
still reject them as unknown API levels.

Example:

```bash
cd android/scanner-app
./scripts/run-connected-android-tests.sh \
  --class za.co.voelgoed.fastcheck.app.MainActivityCameraRecoveryFlowTest
```

## Worker Tests

Worker tests should verify:

- batch chunking at `50`
- retry on retryable failures
- auth-expiry stop behavior
- no direct dependency on scanner UI code

## Contract Discipline

No Android test should reference future scanner routes as active dependencies.

### Change-set claim boundaries

When writing PR notes or release notes for sync/persistence changes:

- Keep DAO persistence claims to: **single DAO entrypoint persists both tables**.
- Do **not** claim rollback/all-or-nothing behavior unless a test triggers an in-transaction DB failure and proves no partial commit.
- Claim hardened Retry-After support only when the parser and associated tests are present in the merged codebase.
- If needed, split `Retry-After` correctness into a dedicated follow-up PR.

Reason-code coverage must also prove:

- `status` and row presence still decide terminal vs retryable behavior
- `reason_code` is optional and additive only
- proven refinements are only `replay_duplicate`, `business_duplicate`, and
  `payment_invalid`
- `replay_duplicate` is trusted only for final replay duplicates
- `message` is not contract truth
- missing result rows after HTTP 200 remain retryable
