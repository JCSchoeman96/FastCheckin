# Priority 2 — Real Operator Controls

## Authority and documents

- **[priority-2.1-authority-current-baseline-and-regression-plan.md](priority-2.1-authority-current-baseline-and-regression-plan.md)** is the **active contract** for Priority 2 (post–Priority 1 baseline, gaps, PR split, file lists, tests).
- **This document** is **derived execution detail and historical context** (corrections, recommended splits, copy-paste prompts). It is **not** a second source of truth over 2.1. If anything conflicts, **2.1 wins**.
- The **v3 execution plan** in `.cursor/plans/priority-2.2-operator-controls.plan.md` states scope locks (e.g. no `Relogin` until PR 2C) and minimum tests for agents.

## Purpose

Priority 2 hardens the Android scanner app's operator recovery surfaces so the app does not merely **describe** problems, but also gives gate staff and supervisors clean, truthful ways to recover during live operations.

This priority must **not** become a new admin console.

The repo already has:

- queue/upload state
- sync state
- diagnostics state
- session gate/login shell
- support surface scaffolding

The real gap is action wiring and operator-facing intervention flow.

---

## Corrections to the Base Priority Doc

The base Priority 2 doc is directionally right, but a few points need tightening against the current repo.

### Correction 1 — Scan already has retry-upload

`ScanDestinationScreen` already renders a conditional **Retry upload** action when the presenter says it should be visible. This work is therefore **not** "add retry upload to Scan from scratch." The missing work is:

- manual sync access from Scan
- better action orchestration on Scan
- Event-screen recovery controls
- auth-expired re-login intervention

### Correction 2 — Event is status-only, not action-ready

`EventDestinationScreen` and `EventDestinationUiState` are currently read-only. There is no action row, no button model, and no callback path for operator recovery.

### Correction 3 — Support is scanner-recovery-only today

`SupportOverviewRoute` currently only consumes `ScanningViewModel`, and `SupportOverviewPresenter` only projects scanner permission/source recovery. That means Support is not yet wired to queue, sync, or auth-expired operational recovery.

### Correction 4 — Diagnostics already has enough data

`DiagnosticsViewModel` and `DiagnosticsUiStateFactory` already combine session, token presence, sync status, queue depth, latest flush report, connectivity, and upload semantic state. Do not build a new diagnostics subsystem. Tighten wording and route recovery actions around the data that already exists.

### Correction 5 — Re-login must be a deliberate operator path

The repo already has a session gate and logout/login shell. The missing part is not session architecture. The missing part is a **truthful operator re-login intervention path** from auth-expired operational states.

---

## Non-Negotiable Truth Rules

These rules apply to every PR in this priority.

1. **Queued locally is still durable local truth.**
   Re-login must not silently discard queued scans.

2. **Auth expired is an intervention state, not a hidden background state.**
   The operator must be shown what happened and what to do next.

3. **Manual sync is secondary.**
   It is a recovery control, not the center of the operator flow.

4. **Support is still operator support, not an admin dashboard.**
   Keep it calm, operational, and task-oriented.

5. **Diagnostics remains read-only.**
   Recovery actions may route from nearby support surfaces, but diagnostics itself should not turn into a command center.

6. **Do not create a new auth-refresh system.**
   Reuse the existing session gate / logout / login flow unless the repo already has a true refresh-token model, which it does not.

---

## Architecture Boundaries

### Keep

- `MainActivity` as the high-level shell wiring point
- `SessionGateViewModel` as the authenticated/logged-out route gate
- `SyncViewModel.syncAttendees()` for manual sync
- `QueueViewModel.flushQueuedScans()` for retry upload
- `DiagnosticsViewModel` and `DiagnosticsUiStateFactory` as the diagnostics data source
- `SupportOverviewRoute` as the support entry point

### Avoid

- no new backend endpoints
- no new diagnostics repository
- no new support-specific state store
- no Event-screen analytics expansion
- no shell redesign
- no mixing scanner recovery and operational recovery into one vague enum without structure

---

## Recommended PR Split

Implement Priority 2 in **four PRs**.

### PR 2A — Event and Scan operator action surfacing
- **Branch:** `codex/priority2-event-scan-operator-actions`
- **PR title:** `[codex] priority 2 event and scan operator actions`

### PR 2B — Support overview operational recovery expansion
- **Branch:** `codex/priority2-support-operational-recovery`
- **PR title:** `[codex] priority 2 support operational recovery`

### PR 2C — Auth-expired re-login intervention flow
- **Branch:** `codex/priority2-auth-expired-relogin-flow`
- **PR title:** `[codex] priority 2 auth expired relogin flow`

### PR 2D — Diagnostics wording and recovery truth-locks
- **Branch:** `codex/priority2-diagnostics-wording-locks`
- **PR title:** `[codex] priority 2 diagnostics wording locks`

### Why this split

- **PR 2A** introduces action affordances where operators already work.
- **PR 2B** upgrades Support from scanner-only recovery to real operational support.
- **PR 2C** adds the riskiest intervention path — re-login — after the action surfaces exist.
- **PR 2D** locks copy, wording, and support/diagnostics truth after the flows are in place.

Do **not** collapse all four into one PR. That will create review noise and confuse truth boundaries.

---

## Recommended Execution Order

1. **PR 2A — Event and Scan operator action surfacing**
2. **PR 2B — Support overview operational recovery expansion**
3. **PR 2C — Auth-expired re-login intervention flow**
4. **PR 2D — Diagnostics wording and recovery truth-locks**

Do not start with diagnostics wording. That is backward.

---

# PR 2A — Event and Scan Operator Action Surfacing

## What this PR is

Turn the existing Event and Scan surfaces into operator-usable recovery surfaces using the viewmodels that already exist.

## Why this PR comes first

Because the repo already has the recovery operations:

- `SyncViewModel.syncAttendees()`
- `QueueViewModel.flushQueuedScans()`

The missing piece is **operator affordance**, especially on Event.

## Repo Grounding

- Scan already supports a conditional **Retry upload** button.
- Scan does **not** expose manual sync.
- Event is currently read-only and has no action row at all.

## Goal

After this PR:

- Scan can expose **Manual sync** when appropriate
- Event can expose **Manual sync** and **Retry upload** when appropriate
- action visibility is deterministic and presenter-driven
- no auth-expired re-login CTA yet unless needed for plumbing only

## Files Expected to Change

### Update
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/event/EventDestinationRoute.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/event/EventDestinationPresenter.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/event/EventDestinationScreen.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/event/EventDestinationUiState.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/scanning/screen/ScanDestinationRoute.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/scanning/screen/ScanDestinationPresenter.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/scanning/screen/ScanDestinationScreen.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/app/MainActivity.kt`

### Test
- `android/scanner-app/app/src/test/java/za/co/voelgoed/fastcheck/feature/event/EventDestinationPresenterTest.kt`
- `android/scanner-app/app/src/test/java/za/co/voelgoed/fastcheck/feature/scanning/screen/ScanDestinationPresenterTest.kt`
- add new focused tests if existing files become too crowded

## Implementation Plan

### 1. Add explicit UI action models
Add small, deterministic action models rather than scattering button booleans.

Recommended shape:

- `EventActionUiModel`
- `ScanActionUiModel`

Keep them simple:

- `label`
- `action`
- `isPrimary` if needed
- no icon system unless already present elsewhere

### 2. Add operator action enums per surface
Do **not** reuse `SupportRecoveryAction` here.

Recommended:

- `EventOperatorAction`
- `ScanOperatorAction`

For this PR they likely include:

- `ManualSync`
- `RetryUpload`

Do **not** add `Relogin` yet unless you need a placeholder in the action model for later PR wiring.

### 3. Event presenter decides visibility
Add presenter rules so Event actions appear only when meaningful.

Recommended rules:

- **Manual sync** visible when:
  - not currently syncing
  - authenticated event session exists
  - always allowed as secondary action, or at minimum when attendee cache is unavailable/stale/failed
- **Retry upload** visible when:
  - local queue depth > 0
  - upload state is partial / retry scheduled / retryable failed
  - not offline-only with automatic resume expected
  - not auth-expired in this PR unless you intentionally reserve the slot for PR 2C

### 4. Scan presenter adds manual sync action
Do not rebuild Scan action logic from scratch.

Preserve the existing retry-upload visibility logic and add manual sync as a second operational recovery action near Scan health or Attendee readiness.

### 5. Route callbacks from Event and Scan
`EventDestinationRoute` and `ScanDestinationRoute` should accept callbacks such as:

- `onManualSync`
- `onRetryUpload`

Wire them from `MainActivity` to:

- `syncViewModel::syncAttendees`
- `queueViewModel::flushQueuedScans`

### 6. Keep copy operational
Examples:

- "Sync attendee list"
- "Retry upload"
- not "Force refresh"
- not "Retry worker"
- not "Execute sync pipeline"

## Acceptance Criteria

- Event screen shows operator recovery actions when meaningful
- Scan exposes manual sync without breaking existing retry-upload behavior
- no new diagnostics subsystem exists
- no backend contract changes
- presenter tests lock visibility rules

## Risks / Edge Cases

- showing manual sync while a sync is already in progress
- showing retry upload during auth-expired where re-login is actually needed
- showing retry upload when queue depth is zero
- placing actions too high in hierarchy and cluttering the scan loop
- collapsing Event and Scan actions into one shared over-general abstraction too early

## Copy-Paste Codex Prompt

| Field | Content |
|---|---|
| Task | Surface real operator recovery actions on the Event and Scan destinations using the existing sync and queue viewmodels. |
| Objective | Turn read-only status surfaces into operator-usable recovery surfaces without building a new subsystem. |
| Output | Event and Scan UI-state/action-model updates, route callback wiring, screen updates, and focused presenter tests. |
| Note | Reuse `SyncViewModel.syncAttendees()` and `QueueViewModel.flushQueuedScans()`. Scan already has retry-upload behavior; preserve and refine it rather than rebuilding it. Event currently has no action model and needs one. Keep actions deterministic and presenter-driven. Manual sync stays secondary. Do not add re-login behavior in this PR except minimal model plumbing if required for the next PR. No diagnostics expansion, no backend changes, no shell redesign. |

---

# PR 2B — Support Overview Operational Recovery Expansion

## What this PR is

Expand Support so it can help with operational recovery, not just scanner permission/source issues.

## Why this PR comes second

Because once Event and Scan have explicit action semantics, Support can mirror and centralize the same recovery options without becoming a second product.

## Current Repo Problem

`SupportOverviewRoute` only reads `ScanningViewModel`, and `SupportOverviewPresenter` only projects scanner recovery. That is too narrow for live gate operations.

## Goal

After this PR:

- Support can show scanner recovery **and** operational recovery
- Support can offer:
  - manual sync
  - retry upload
  - request camera access
  - open app settings
  - return to scan
- Support remains structured and calm
- Support still does not become diagnostics itself

## Files Expected to Change

### Update
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/support/SupportOverviewRoute.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/support/SupportOverviewPresenter.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/support/SupportOverviewScreen.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/support/SupportOverviewUiState.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/app/MainActivity.kt`

### Potentially Create
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/support/SupportOperationalState.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/support/SupportOperatorAction.kt`

### Test
- new `SupportOverviewPresenterTest.kt`
- update/add support route or action-mapping tests as needed

## Implementation Plan

### 1. Give Support route the right state inputs
Support should observe more than scanning state.

Recommended inputs:

- `ScanningViewModel`
- `QueueViewModel`
- `SyncViewModel`

Do not inject repositories directly into Support route.

### 2. Separate scanner recovery from operational recovery
Do not overload one card with unrelated actions.

Recommended screen structure:

- **Scanner recovery** card
- **Operations** card
- **Diagnostics** card
- **Session** card

### 3. Replace the single `recoveryAction` shape if needed
The current UI state only supports one scanner recovery action.

That is too narrow.

Recommended direction:

- keep scanner recovery action as-is or as a list of one
- add a separate operations action list

Example operational actions for this PR:

- `ManualSync`
- `RetryUpload`
- maybe `ReturnToScan` stays in scanner recovery/session contexts, not operations

### 4. Keep support logic presenter-driven
Support presenter should decide:

- what message to show
- what action list is visible
- which actions are hidden when not meaningful

Example:

- `Retry upload` hidden when queue depth == 0
- `Manual sync` hidden or disabled while sync is already in progress
- scanner permission actions only shown when camera source actually needs them

### 5. Keep diagnostics read-only
The diagnostics card should still just route to diagnostics.

No live controls inside diagnostics in this PR.

## Acceptance Criteria

- Support can help with sync/upload recovery, not just scanner permission recovery
- the support screen remains calm and operator-facing
- diagnostics stays a separate read-only surface
- presenter tests lock visibility and wording

## Risks / Edge Cases

- making Support too noisy
- duplicating Event and Scan in full inside Support
- mixing scanner-state messages with queue/auth problems in one blob of text
- adding operational actions that do not respect current queue/sync state

## Copy-Paste Codex Prompt

| Field | Content |
|---|---|
| Task | Expand the Support overview so it can surface operational recovery actions in addition to existing scanner recovery actions. |
| Objective | Make Support useful during real gate recovery without turning it into a second dashboard. |
| Output | Support route/presenter/ui-state/screen updates, MainActivity action wiring updates, and focused presenter/action tests. |
| Note | Support currently reads only `ScanningViewModel`; extend it to also reflect queue and sync recovery state through the existing viewmodels. Keep scanner recovery and operational recovery as separate sections/cards. Add operator-safe actions like manual sync and retry upload only when meaningful. Diagnostics stays read-only and separate. No backend changes, no new diagnostics repository, no shell redesign. |

---

# PR 2C — Auth-Expired Re-Login Intervention Flow

## What this PR is

Add a clean, explicit operator re-login path when queued uploads cannot continue because authentication expired.

## Why this PR comes third

Because the Event, Scan, and Support surfaces need action slots before they can offer a truthful re-login intervention.

## Current Repo Problem

The repo can already **describe** auth-expired states:

- Scan health banner can say re-login is required
- Event attention banner can say re-login is required
- queue/upload semantic state can reflect auth-expired

But none of those surfaces currently provide a first-class re-login action.

## Goal

After this PR:

- Event shows a re-login CTA when auth-expired blocks upload
- Scan shows a re-login CTA when auth-expired blocks upload
- Support shows a re-login CTA when auth-expired blocks upload
- the re-login path reuses the existing logout/login route
- queued scans remain preserved on-device
- wording is explicit that queued uploads continue only after sign-in

## Files Expected to Change

### Update
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/app/MainActivity.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/event/EventDestinationPresenter.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/event/EventDestinationUiState.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/event/EventDestinationScreen.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/scanning/screen/ScanDestinationPresenter.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/scanning/screen/ScanDestinationScreen.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/support/SupportOverviewPresenter.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/support/SupportOverviewUiState.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/support/SupportOverviewScreen.kt`
- possibly `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/app/shell/AppShellViewModel.kt` only if needed for cleaner re-login routing state

### Test
- Event presenter tests
- Scan presenter tests
- Support presenter tests
- focused MainActivity / route-action tests if present patterns allow it

## Implementation Plan

### 1. Add explicit `Relogin` action types
Extend the operator action models introduced earlier to include `Relogin`.

Keep action naming user-facing:

- label: `Re-login`
- maybe supporting copy: `Sign in again to continue queued uploads`

### 2. Define visibility precisely
Show re-login only when:

- queue depth > 0
- upload semantic state is auth-expired

Do not show it:

- for retryable failures
- for offline pause
- for empty queues

### 3. Reuse session gate flow
Do not invent token refresh.

Recommended path:

- action callback from surface -> `MainActivity`
- `MainActivity` triggers existing logout-to-login-gate route in a deliberate, truthful way

### 4. Preserve queue truth during re-login
Current logout behavior already keeps queued scans on-device and warns the operator when queued scans remain.

This PR should preserve that truth.

If you need a dedicated re-login helper, it must still preserve the same queue-retention contract.

### 5. Use contextual copy
Suggested patterns:

- `Re-login required`
- `3 scans are still queued locally and cannot upload until the operator signs in again.`
- button: `Re-login`

Avoid:

- `Refresh token`
- `Resume worker`
- `Restart session`

## Acceptance Criteria

- auth-expired states on Event, Scan, and Support all provide an explicit re-login path
- no queued scans are silently discarded
- the app reuses the current login gate flow
- retryable/offline failures do not get mislabeled as re-login-required

## Risks / Edge Cases

- accidentally routing generic failures to re-login
- re-login action bypassing queue-preservation truth
- duplicated or conflicting CTAs on the same screen
- auth-expired state disappearing before the operator understands what happened

## Copy-Paste Codex Prompt

| Field | Content |
|---|---|
| Task | Add explicit re-login intervention wiring for auth-expired upload states across Event, Scan, and Support. |
| Objective | Stop auth-expired queue/upload states from becoming dead-end banners. |
| Output | Action-model/presenter/screen updates plus MainActivity callback wiring for a truthful re-login flow. |
| Note | Reuse the existing session gate/logout/login route. Do not invent token refresh or a new auth subsystem. Re-login must only appear for true auth-expired upload states with queued scans remaining. Preserve queued scans on-device. Keep wording operator-facing and calm: queued scans remain local and upload can continue after sign-in. |

---

# PR 2D — Diagnostics Wording and Recovery Truth-Locks

## What this PR is

Tighten the wording and tests around diagnostics/support so the app tells the truth consistently after the earlier recovery flows land.

## Why this PR comes last

Because wording locks are only useful after the behaviors are in place.

## Goal

After this PR:

- diagnostics wording matches actual recovery options
- support wording matches actual action behavior
- auth-expired / retryable / offline / queued-local language stays stable
- focused tests stop future semantic drift

## Files Expected to Change

### Update
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/diagnostics/DiagnosticsUiStateFactory.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/support/SupportOverviewPresenter.kt`
- optionally any small wording-only presenter or ui-state files touched by earlier PRs
- docs if wording lock references need updating

### Test
- `android/scanner-app/app/src/test/java/za/co/voelgoed/fastcheck/feature/diagnostics/DiagnosticsUiStateFactoryTest.kt`
- `android/scanner-app/app/src/test/java/za/co/voelgoed/fastcheck/feature/support/SupportDiagnosticsPresenterTest.kt`
- `SupportOverviewPresenterTest.kt`
- any new truth-lock tests for Event/Scan/Support recovery wording

## Implementation Plan

### 1. Review wording against actual behavior
Check for wording that overpromises or is now stale.

Examples to tighten if needed:

- diagnostics implying a control exists where only visibility exists
- support implying action where only guidance exists
- re-login wording that hides queued-local retention

### 2. Add focused truth-lock tests
Protect wording around:

- queued locally
- uploads paused offline
- retry upload
- re-login required
- diagnostics read-only role

### 3. Keep diagnostics factual
Diagnostics should summarize:

- event/session
- sync state
- queue depth
- upload state
- server result summary

But it should not imply it can fix those states directly.

## Acceptance Criteria

- diagnostics wording is consistent with actual recovery capabilities
- support wording is consistent with actual action routing
- tests catch semantic drift

## Risks / Edge Cases

- wording drift after future queue/auth changes
- diagnostics reintroducing admin-console behavior by language only
- support copy becoming too technical

## Copy-Paste Codex Prompt

| Field | Content |
|---|---|
| Task | Tighten diagnostics and support wording so the recovery guidance matches the actual flows implemented in Priority 2, and add focused truth-lock tests. |
| Objective | Prevent semantic drift between operator copy and real recovery behavior. |
| Output | Diagnostics/support wording updates and focused presenter/factory tests that lock key operator truths. |
| Note | Diagnostics data already exists. Keep this PR to wording, state semantics, and tests. Protect language around queued-local truth, retryable upload failures, offline pause, and auth-expired re-login. Diagnostics must remain read-only. Avoid broad UI churn or new data sources. |

---

## Full Test Strategy for Priority 2

### Must-have test categories

- Event presenter action visibility tests
- Scan presenter action visibility tests
- Support presenter action visibility tests
- diagnostics wording tests
- auth-expired recovery wording tests
- route/callback tests where cheap and stable

### Explicit regression traps to prevent

- Event stays status-only because button wiring was skipped
- Scan action logic is rewritten and existing retry-upload behavior regresses
- Support becomes scanner-only again after refactors
- auth-expired is shown without a way forward
- retryable failure is mislabeled as auth-expired
- diagnostics starts implying it can perform recovery actions directly

### What not to add

- no broad UI screenshot suite
- no new repositories for support/diagnostics state
- no background auth-refresh machinery
- no Event analytics expansion
- no shell redesign

---

## What to Reject from Codex

Push back if Codex:

- tries to create a new support/operations subsystem instead of wiring the existing viewmodels
- rebuilds Scan retry-upload behavior instead of preserving/refining it
- turns diagnostics into an interactive command surface
- invents token refresh or refresh-token logic
- routes generic failure to re-login
- hides urgent operator actions only in Support when they belong on Event or Scan
- expands into unrelated Event dashboard work
- introduces heavy abstractions for simple action models

---

## End Goal Summary

Priority 2 succeeds when the Android scanner app stops being a passive status viewer and becomes a **truthful operator recovery tool**.

That means:

- Event and Scan expose the right recovery actions
- Support can help with real operational recovery, not only camera recovery
- auth-expired has a clear re-login path
- diagnostics remains factual and read-only
- queued-local truth stays intact
- no false admin-console behavior leaks into the product

