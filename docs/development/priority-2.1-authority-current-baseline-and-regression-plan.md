# Priority 2 — Real Operator Controls (Current Baseline)

**Status:** Regenerated from current `main` after Priority 1 local-admission rollout  
**Scope:** `android/scanner-app/` only  
**Purpose:** Finish the operator recovery surfaces that are still missing after the local-first admission baseline shipped. This priority makes Event, Scan, Support, and auth-expired states operationally usable without turning the app into an admin console.

---

## 1. Why this priority still exists

Priority 1 moved the scanner app further than the old plan expected.

The app is now explicitly **local-first**:
- local admission decisions come from synced attendee cache plus unresolved local admission overlays
- accepted local admissions queue background reconciliation
- Search/detail/manual admit now sit on top of that local-admission runtime
- Event and Support already consume some merged local truth

That means Priority 2 is **not** starting from a blank scanner shell anymore.

But the core recovery gap still remains:

- **Event** still tells the operator what is wrong, but gives no way to act.
- **Scan** still exposes only `Retry upload`, not the broader operational recovery controls the operator needs.
- **Support** now shows reconciliation messaging, but still only exposes scanner/device recovery actions.
- **Auth-expired** still stops at banners and login-gate routing. It does not yet give the operator a deliberate re-login CTA from the surfaces where the problem is encountered.
- **Diagnostics** already has the data. The remaining problem is wording and truth-locking, not a missing diagnostics backend.

So Priority 2 remains valid, but it must now start from the **current post-Priority-1 runtime baseline**, not the old pre-local-admission baseline.

---

## 2. Current runtime baseline this priority must respect

This document assumes the repo state that is now on `main`.

### Current truths already on `main`

- Android runtime is documented as **local-first**, with synced attendee rows as server-synced base truth and overlays as operational gate truth.
- Search/detail/manual admit already exists on top of that runtime.
- Event already consumes merged event metrics including active overlays and unresolved conflicts.
- Support already surfaces reconciliation warnings from merged local truth.
- Cross-event unresolved state blocking already exists in the session boundary.

### What is already solved and must not be rebuilt

- No new backend APIs are needed for Priority 2.
- No new diagnostics repository is needed.
- No new support-specific persistence layer is needed.
- No shell redesign is needed.
- No token refresh subsystem is needed.

### What still remains unsolved

- Event has no action model and no action callbacks.
- Scan has `Retry upload`, but not `Manual sync` or `Re-login` action affordances.
- Support action enum still only includes:
  - `RequestCameraAccess`
  - `OpenAppSettings`
  - `ReturnToScan`
- Support route still does not observe queue or sync viewmodels directly.
- Auth-expired is visible in Event/Scan banners, but there is no first-class operator CTA to re-login from those surfaces.
- Diagnostics wording still needs to be locked against the new local-admission runtime and operator control behavior.

---

## 3. Repo grounding for the new Priority 2

The following files define the real starting point.

### Event surface

- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/event/EventDestinationRoute.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/event/EventDestinationPresenter.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/event/EventDestinationUiState.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/event/EventDestinationScreen.kt`
- `android/scanner-app/app/src/test/java/za/co/voelgoed/fastcheck/feature/event/EventDestinationPresenterTest.kt`

### Scan surface

- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/scanning/screen/ScanDestinationRoute.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/scanning/screen/ScanDestinationPresenter.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/scanning/screen/ScanDestinationScreen.kt`
- `android/scanner-app/app/src/test/java/za/co/voelgoed/fastcheck/feature/scanning/screen/ScanDestinationPresenterTest.kt`

### Support surface

- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/support/SupportOverviewRoute.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/support/SupportOverviewPresenter.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/support/SupportOverviewUiState.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/support/SupportOverviewScreen.kt`
- `android/scanner-app/app/src/test/java/za/co/voelgoed/fastcheck/feature/support/SupportOverviewPresenterTest.kt`

### Auth/session boundary and shell wiring

- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/app/MainActivity.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/app/session/SessionGateViewModel.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/data/repository/CurrentPhoenixSessionRepository.kt`

### Existing sync/queue/diagnostics sources to reuse

- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/sync/SyncViewModel.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/queue/QueueViewModel.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/queue/QueueUiState.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/diagnostics/DiagnosticsUiStateFactory.kt`

### Current repo facts this plan is grounded in

1. **Event is still read-only.** It renders status chip, banner, and metric cards, but no action model or callback path exists.
2. **Scan already has retry-upload**, but no manual sync or re-login CTA surface.
3. **Support now includes reconciliation messaging**, but the action enum is still limited to camera/settings/return.
4. **Support still does not observe queue/sync viewmodels directly**.
5. **Auth-expired is already visible in Event/Scan wording**, but still lacks explicit re-login action flow.
6. **MainActivity already owns the right wiring points** for recovery callbacks and session-gate/login routing.
7. **Diagnostics already has the right data shape** and should stay read-only.

---

## 4. Non-negotiable truth rules

These rules apply to every PR in this priority.

### Rule 1 — Queued scans remain durable local truth
A recovery action must not silently discard queued scans.

### Rule 2 — Auth-expired is an intervention state
It is not a background detail and not just another retryable failure.

### Rule 3 — Manual sync stays secondary
It is a recovery action, not the main scanning workflow.

### Rule 4 — Support is still operator support
Do not turn Support into a dashboard or admin console.

### Rule 5 — Diagnostics remains factual and read-only
Recovery actions may route from neighboring surfaces, but diagnostics itself must not become interactive control infrastructure.

### Rule 6 — Re-login reuses the existing session/login boundary
Do not invent refresh-token logic.

### Rule 7 — Event and Scan should expose urgent recovery where the operator already is
Do not hide all important actions in Support.

### Rule 8 — Upload failure categories must remain truthful
- offline pause != auth-expired
- retryable != auth-expired
- queued locally != uploaded

---

## 5. What Priority 2 means now

Priority 2 is no longer “make the scanner app less passive” in the abstract.

It is now specifically:

1. add **operator actions** to Event and Scan
2. expand Support from **scanner recovery only** into **scanner + operational recovery**
3. add **explicit re-login intervention** where auth-expired blocks uploads
4. lock wording and tests so the new local-admission runtime and recovery behavior do not drift

That is the correct remaining scope after Priority 1 shipped.

---

## 6. Recommended folder and naming strategy

Keep the work inside the current feature boundaries.

### Do use
- `feature/event/` for Event actions
- `feature/scanning/screen/` for Scan action surfacing
- `feature/support/` for Support action surfacing
- `feature/diagnostics/` for wording/factory truth locks only

### Do not introduce
- `feature/operations/`
- `feature/admin/`
- `feature/recovery/`
- new support-specific repositories

### Recommended new model files

```text
android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/
  feature/
    event/
      model/
        EventOperatorAction.kt
        EventOperatorActionUiModel.kt
    scanning/
      screen/
        model/
          ScanOperatorAction.kt
          ScanOperatorActionUiModel.kt
    support/
      model/
        SupportOperationalAction.kt
        SupportOperationalActionUiModel.kt
```

Keep models small and explicit.

---

## 7. Recommended PR split

Use **four PRs**.

| PR | Branch | PR Title | Depends On | Purpose |
|---|---|---|---|---|
| PR 2A | `codex/p2-event-scan-operator-actions` | `[codex] p2 event and scan operator actions` | `main` | Add operator action models and action callbacks to Event and Scan. |
| PR 2B | `codex/p2-support-operational-recovery` | `[codex] p2 support operational recovery` | PR 2A | Expand Support to reflect queue/sync/auth operational recovery, not just camera recovery. |
| PR 2C | `codex/p2-auth-expired-relogin-flow` | `[codex] p2 auth expired relogin flow` | PR 2B | Add explicit re-login CTAs and wiring for auth-expired upload states. |
| PR 2D | `codex/p2-diagnostics-truth-locks` | `[codex] p2 diagnostics wording and truth locks` | PR 2C | Lock wording and semantic tests after the behavior is in place. |

### Why this split is now correct

- PR 2A finishes the missing operator actions where operators already work.
- PR 2B upgrades Support without duplicating Event/Scan.
- PR 2C adds the highest-risk intervention path only after action models exist.
- PR 2D locks semantics after the flows are real.

Do **not** combine all of this into one PR.

---

## 8. Worktree setup

```bash
git fetch origin
git worktree add ../fastcheck-p2-pr1 -b codex/p2-event-scan-operator-actions origin/main
git worktree add ../fastcheck-p2-pr2 -b codex/p2-support-operational-recovery origin/main
git worktree add ../fastcheck-p2-pr3 -b codex/p2-auth-expired-relogin-flow origin/main
git worktree add ../fastcheck-p2-pr4 -b codex/p2-diagnostics-truth-locks origin/main
```

Use a stacked flow:
- PR 2A from `main`
- PR 2B from PR 2A
- PR 2C from PR 2B
- PR 2D from PR 2C

---

# 9. PR 2A — Event and Scan operator actions

## 9.1 Goal

Add explicit operator action affordances to Event and Scan using the viewmodels that already exist.

## 9.2 Why this PR comes first

Because the app already has the underlying recovery operations:
- `SyncViewModel.syncAttendees()`
- `QueueViewModel.flushQueuedScans()`

The missing piece is the operator-facing action surface.

## 9.3 Current gap to close

### Event
- reads queue/sync/metrics
- already shows banners for offline, auth-expired, backlog, and conflicts
- still has **no action UI model** and **no action callback path**

### Scan
- already has `Retry upload`
- still lacks:
  - `Manual sync`
  - explicit action model
  - future-ready `Re-login` action slot

## 9.4 Files to create

- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/event/model/EventOperatorAction.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/event/model/EventOperatorActionUiModel.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/scanning/screen/model/ScanOperatorAction.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/scanning/screen/model/ScanOperatorActionUiModel.kt`

## 9.5 Files to update

- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/event/EventDestinationPresenter.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/event/EventDestinationUiState.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/event/EventDestinationScreen.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/event/EventDestinationRoute.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/scanning/screen/ScanDestinationPresenter.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/scanning/screen/ScanDestinationUiState.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/scanning/screen/ScanDestinationScreen.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/scanning/screen/ScanDestinationRoute.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/app/MainActivity.kt`

## 9.6 Exact implementation requirements

### Event action model
Add presenter-driven actions such as:
- `ManualSync`
- `RetryUpload`

Visibility rules must be deterministic:
- `Manual sync` shown when sync is not already running
- `Retry upload` shown when queue depth > 0 and upload state is retryable/partial/retry-scheduled
- no `Re-login` action in this PR unless minimal enum plumbing is needed for PR 2C

### Scan action model
Do not rewrite Scan from scratch.

Add:
- `ManualSync`
- preserve existing `RetryUpload`

### Route wiring
Add route callbacks:
- `onManualSync`
- `onRetryUpload`

Wire them from `MainActivity` to:
- `syncViewModel::syncAttendees`
- `queueViewModel::flushQueuedScans`

### Screen layout guidance
- Event: action row or action card near status/attention area
- Scan: action row inside or just below “Scan health” card
- keep action count small
- do not clutter the scan loop

## 9.7 Copy guidance

Use operator-facing labels only:
- `Sync attendee list`
- `Retry upload`

Do not use:
- `Run sync pipeline`
- `Restart worker`
- `Force upload`

## 9.8 Acceptance criteria

- Event is no longer status-only
- Scan exposes manual sync in addition to retry upload when meaningful
- actions are presenter-driven
- no new subsystem exists
- no backend contract changes

## 9.9 Required tests

### Update or add
- `android/scanner-app/app/src/test/java/za/co/voelgoed/fastcheck/feature/event/EventDestinationPresenterTest.kt`
- `android/scanner-app/app/src/test/java/za/co/voelgoed/fastcheck/feature/scanning/screen/ScanDestinationPresenterTest.kt`
- add focused route/action tests if needed

### Must cover
- Event shows `Manual sync` only when sync not in progress
- Event shows `Retry upload` only when backlog is meaningful
- Scan preserves retry-upload behavior for partial/retryable backlog
- Scan hides retry-upload for offline pause
- action labels remain operator-facing
- auth-expired is still banner-only at this stage

## 9.10 TOON prompt — PR 2A

| Field | Content |
|---|---|
| Task | Add explicit operator action models and action callbacks to the Event and Scan destinations using the existing sync and queue viewmodels. |
| Objective | Finish the missing operator affordances on Event and Scan without redesigning the shell or building a new recovery subsystem. |
| Output | Event/Scan action models, presenter updates, screen updates, route callback wiring in `MainActivity`, and focused presenter tests. |
| Note | Event is currently read-only and must gain an action model. Scan already has retry-upload and must preserve that behavior while adding manual sync. Reuse `SyncViewModel.syncAttendees()` and `QueueViewModel.flushQueuedScans()`. Keep actions deterministic and presenter-driven. Do not add re-login behavior yet except minimal future-proof enum plumbing if required. No backend changes, no diagnostics expansion, no shell redesign. |

---

# 10. PR 2B — Support operational recovery

## 10.1 Goal

Upgrade Support from “scanner recovery plus reconciliation messaging” to a real operator recovery surface for scanner + sync/upload issues.

## 10.2 Why this PR comes second

Because Support should mirror the action semantics already introduced in Event and Scan, not invent its own competing logic first.

## 10.3 Current gap to close

Support currently:
- observes `ScanningViewModel`
- observes `EventMetricsViewModel`
- can show reconciliation messaging
- can only act through `SupportRecoveryAction` values:
  - `RequestCameraAccess`
  - `OpenAppSettings`
  - `ReturnToScan`

That is still too narrow for live operator recovery.

## 10.4 Files to create

- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/support/model/SupportOperationalAction.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/support/model/SupportOperationalActionUiModel.kt`

## 10.5 Files to update

- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/support/SupportOverviewRoute.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/support/SupportOverviewPresenter.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/support/SupportOverviewUiState.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/support/SupportOverviewScreen.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/app/MainActivity.kt`

Likely route additions:
- `queueViewModel: QueueViewModel`
- `syncViewModel: SyncViewModel`

## 10.6 Exact implementation requirements

### Route inputs
Support should observe:
- `ScanningViewModel`
- `EventMetricsViewModel`
- `QueueViewModel`
- `SyncViewModel`

Do not inject repositories directly into the route.

### Screen structure
Split Support into calm sections:
- `Scanner recovery`
- `Operations`
- `Diagnostics`
- `Session`

Do not collapse everything into one banner.

### Operational action list
Add actions like:
- `ManualSync`
- `RetryUpload`
- keep camera/settings/return actions separate from operations

### Presenter rules
- `Retry upload` hidden when queue depth == 0
- `Manual sync` hidden or disabled when sync already running
- reconciliation message remains informational unless a future conflict workflow is added
- diagnostics stays route-only

## 10.7 Acceptance criteria

- Support can help with sync/upload recovery as well as camera recovery
- scanner and operational actions are clearly separated
- diagnostics remains read-only
- Support still feels operator-facing, not administrative

## 10.8 Required tests

### Update or add
- `android/scanner-app/app/src/test/java/za/co/voelgoed/fastcheck/feature/support/SupportOverviewPresenterTest.kt`
- add additional support route/presenter tests if needed

### Must cover
- operational actions appear when meaningful
- no backlog -> no retry-upload action
- sync in progress -> manual sync hidden/disabled
- scanner recovery copy still works
- reconciliation warnings remain visible alongside operations
- diagnostics remains route-only language

## 10.9 TOON prompt — PR 2B

| Field | Content |
|---|---|
| Task | Expand Support so it can surface operational recovery actions in addition to scanner recovery actions, using existing queue and sync viewmodels. |
| Objective | Make Support useful during live gate recovery without turning it into an admin console or duplicating Event/Scan in full. |
| Output | Support route/presenter/ui-state/screen updates, MainActivity callback wiring, support operational action models, and focused presenter tests. |
| Note | Support already has reconciliation messaging from Priority 1, but its action enum is still limited to camera/settings/return. Extend it to reflect queue/sync recovery too. Keep scanner recovery and operations as separate sections. Diagnostics stays read-only and separate. No backend changes, no new repository layer, no shell redesign. |

---

# 11. PR 2C — Auth-expired re-login flow

## 11.1 Goal

Add explicit re-login CTAs and routing for auth-expired upload states across Event, Scan, and Support.

## 11.2 Why this PR comes third

Because re-login is the highest-risk operator intervention and should land only after all three surfaces already know how to expose actions.

## 11.3 Current gap to close

Current repo behavior:
- Event can say `Re-login required`
- Scan can say `Re-login required`
- session gate can push blocking messages to auth UI
- session repository already blocks conflicting cross-event login

But the operator still has no **surface-level CTA** to intentionally act.

## 11.4 Files to create or update

### Update
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/event/EventDestinationPresenter.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/event/EventDestinationUiState.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/event/EventDestinationScreen.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/scanning/screen/ScanDestinationPresenter.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/scanning/screen/ScanDestinationUiState.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/scanning/screen/ScanDestinationScreen.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/support/SupportOverviewPresenter.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/support/SupportOverviewUiState.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/support/SupportOverviewScreen.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/app/MainActivity.kt`

### Possibly update
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/auth/AuthViewModel.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/app/shell/AppShellViewModel.kt`

## 11.5 Exact implementation requirements

### Add explicit action types
Extend Event/Scan/Support operator actions to include `Relogin`.

### Visibility rules
Show `Relogin` only when:
- queue depth > 0
- upload semantic state is auth-expired

Do not show it for:
- offline pause
- retryable failures
- empty queue

### Route wiring
Add callbacks such as:
- `onRelogin`

Wire them in `MainActivity` to the existing session/login flow.

Practical direction:
- do not invent refresh-token logic
- route the operator intentionally back through the current login gate
- preserve queue truth while doing so

### Wording guidance
Use calm, explicit copy:
- `Re-login required`
- `2 scans are still queued locally and cannot upload until the operator signs in again.`
- button: `Re-login`

Avoid:
- `Refresh token`
- `Resume worker`
- `Restart session`

## 11.6 Acceptance criteria

- Event, Scan, and Support all provide a clear re-login path for auth-expired backlog states
- queued scans remain preserved
- offline and retryable failures do not get mislabeled as re-login-required
- the action reuses the current session/login route

## 11.7 Required tests

### Update or add
- `android/scanner-app/app/src/test/java/za/co/voelgoed/fastcheck/feature/event/EventDestinationPresenterTest.kt`
- `android/scanner-app/app/src/test/java/za/co/voelgoed/fastcheck/feature/scanning/screen/ScanDestinationPresenterTest.kt`
- `android/scanner-app/app/src/test/java/za/co/voelgoed/fastcheck/feature/support/SupportOverviewPresenterTest.kt`
- `android/scanner-app/app/src/test/java/za/co/voelgoed/fastcheck/app/session/SessionGateViewModelTest.kt`
- `android/scanner-app/app/src/test/java/za/co/voelgoed/fastcheck/data/repository/CurrentPhoenixSessionRepositoryTest.kt`

### Must cover
- auth-expired backlog exposes `Relogin`
- empty queue does not expose `Relogin`
- offline state does not expose `Relogin`
- retryable failure does not expose `Relogin`
- route wiring preserves queued scans
- cross-event unresolved-state blocking still works after re-login plumbing changes

## 11.8 TOON prompt — PR 2C

| Field | Content |
|---|---|
| Task | Add explicit re-login CTAs and callback wiring for auth-expired backlog states across Event, Scan, and Support. |
| Objective | Stop auth-expired queue/upload states from being banner-only dead ends and give the operator a truthful next action. |
| Output | Event/Scan/Support action model updates, presenter/screen changes, MainActivity callback wiring, and focused presenter/session tests. |
| Note | Reuse the existing session/login boundary. Do not add token refresh. Show re-login only for true auth-expired upload states with queued scans remaining. Preserve queued scans. Keep wording calm and operator-facing. Offline and retryable failures must stay distinct from auth-expired. |

---

# 12. PR 2D — Diagnostics wording and truth locks

## 12.1 Goal

Lock diagnostics and operator-recovery wording so future changes do not blur queue truth, auth-expired truth, or the role of diagnostics.

## 12.2 Why this PR comes last

Because wording locks only make sense after the operator actions and re-login behavior are real.

## 12.3 Current gap to close

Diagnostics already has the right data.

What still needs tightening is:
- wording around auth-expired vs offline vs retryable failure
- wording around queued-local truth
- wording around diagnostics being informational, not controlling
- wording across Event/Scan/Support after the new actions land

## 12.4 Files to update

- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/diagnostics/DiagnosticsUiStateFactory.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/support/SupportOverviewPresenter.kt`
- any small presenter/ui-state files touched in earlier PRs if wording needs stabilization
- optional docs if wording lock references need updating

## 12.5 Required tests

- `android/scanner-app/app/src/test/java/za/co/voelgoed/fastcheck/feature/diagnostics/DiagnosticsUiStateFactoryTest.kt`
- `android/scanner-app/app/src/test/java/za/co/voelgoed/fastcheck/feature/support/SupportOverviewPresenterTest.kt`
- add truth-lock tests for Event/Scan/Support wording if needed

### Must cover
- queued-local wording stays explicit
- offline pause wording stays distinct
- retry upload wording stays distinct
- re-login-required wording stays distinct
- diagnostics never implies it can directly perform recovery

## 12.6 Acceptance criteria

- diagnostics wording matches real behavior
- support wording matches real action routing
- Event/Scan wording matches real action availability
- semantic drift becomes harder to reintroduce

## 12.7 TOON prompt — PR 2D

| Field | Content |
|---|---|
| Task | Tighten diagnostics and operator-recovery wording after the Priority 2 actions land, and add focused semantic regression tests. |
| Objective | Prevent future wording drift that blurs queued-local truth, offline pause, retryable failure, and auth-expired re-login behavior. |
| Output | Diagnostics/support wording updates, any small presenter wording fixes in Event/Scan/Support, and focused truth-lock tests. |
| Note | Diagnostics data already exists. Keep this PR to wording, semantics, and tests. Protect language around queued-local truth, offline pause, retryable upload failures, auth-expired re-login, and diagnostics being read-only. No new data sources and no broad UI churn. |

---

## 13. Comprehensive regression test matrix

Priority 2 must add or tighten tests in the following categories.

### Event presenter regressions
- status-only Event no longer remains actionless
- auth-expired banner + `Relogin` action alignment
- offline banner + no `Relogin`
- retryable backlog + `RetryUpload`
- manual sync visibility and disabled states
- merged metrics remain intact while actions are added

### Scan presenter regressions
- existing retry-upload behavior preserved
- manual sync visibility added without changing scan truth
- auth-expired backlog shows re-login CTA only when appropriate
- offline backlog hides retry and relogin appropriately
- queued-local capture copy remains local truth, not server truth

### Support presenter regressions
- camera recovery copy remains intact
- operational actions appear only when meaningful
- reconciliation warning still appears when conflict count > 0
- diagnostics section stays informational
- session/logout copy remains calm and operator-facing

### Session/auth regressions
- re-login CTA routes through current login/session boundary
- queued scans remain preserved
- conflicting cross-event unresolved state still blocks login
- login error path remains operator-readable

### Diagnostics truth-lock regressions
- `Queued locally` copy remains explicit
- offline pause != auth-expired
- retryable failure != auth-expired
- diagnostics summaries remain read-only and factual

---

## 14. Validation commands for every PR

```bash
git diff --check
JAVA_HOME=/home/jcschoeman96/.jdks/jdk-25.0.2+10 bash ./gradlew -Dorg.gradle.java.home=/home/jcschoeman96/.jdks/jdk-25.0.2+10 :app:compileDebugKotlin :app:testDebugUnitTest
```

If any PR touches session/repository logic beyond pure presenter work, also run repo-level checks already used in the project workflow.

---

## 15. What Codex must not do

Reject the PR if Codex does any of this:

- rebuilds Scan retry behavior from scratch
- invents a new diagnostics subsystem
- turns diagnostics into an interactive command surface
- creates a new auth-refresh subsystem
- hides all important actions only in Support
- turns Support into an admin dashboard
- routes generic failure to re-login
- broadens into unrelated Event analytics/dashboard work
- introduces heavy abstractions for simple action models
- conflates queued-local truth with backend-confirmed truth

---

## 16. What success looks like now

Priority 2 succeeds when:

- Event gives the operator a truthful way to act, not just read status
- Scan exposes the missing recovery controls without disrupting the scan loop
- Support can help with scanner and operational recovery without becoming a dashboard
- auth-expired states provide an explicit re-login path
- diagnostics remains factual and read-only
- queued-local, offline, retryable, and auth-expired truths stay clearly distinct

That is the correct post-Priority-1 shape for real operator controls.
