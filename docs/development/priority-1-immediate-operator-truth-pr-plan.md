# Priority 1 — Immediate Operator Truth

> Implementation note: the approved runtime direction has moved beyond the
> earlier queue-first wording in this doc. The Android scanner now uses local
> admission overlays as operational gate truth, keeps synced attendee rows as
> server-synced base truth, blocks cross-event session changes when unresolved
> local state exists, and removes confirmed overlays only after a later
> attendee sync satisfies the catch-up rule.

**Status:** Refactored and expanded execution plan for Codex  
**Scope:** `android/scanner-app/` only  
**Purpose:** Replace the Search stub with a real operator workflow, add truthful attendee detail and manual intervention, then add scan-time local advisory without blurring queue truth and backend truth.

---

## 1. Why this priority exists

This is the operator confidence gap.

The repo already has the local attendee lookup foundation, richer attendee projections, and the Scan/Event shell structure. What it does **not** have yet is the operator workflow that exposes that truth quickly and honestly.

At the moment:

- the shell already includes a `Search` destination, but the UI still renders a stub there
- local attendee lookup already supports exact ticket, ticket prefix, and name/email search
- scan capture still primarily ends in **queue truth** (`Queued locally (pending upload)`)
- there is still no first-class, operator-facing path from scan uncertainty -> local attendee lookup -> attendee detail -> manual fallback action

That is the gap this priority closes.

---

## 2. Corrections to the base doc

Your base doc is directionally correct, but it needs these corrections before Codex touches code:

### Correction A — Use `feature/search/`, not `feature/attendees/`
The current runtime entrypoint is already called **Search**. Do not widen the package to `feature/attendees/` unless you are intentionally building a broader attendee management surface. For this priority, that would be the wrong abstraction.

**Use:**

- `feature/search/`
- `feature/search/detail/`

**Do not use:**

- `feature/attendees/`

### Correction B — Do not re-do the projection foundation as a first implementation PR
The older Phase 11 plan assumed Android was still missing the richer search/detail projection. That is stale.

The repo already has:

- `AttendeeSearchRecord`
- `AttendeeDetailRecord`
- `CurrentAttendeeLookupRepository`
- `AttendeeLookupDao`
- `AttendeeEntity` with `checkedInAt`, `checkedOutAt`, `allowedCheckins`, `checkinsRemaining`, `paymentStatus`, and `isCurrentlyInside`

So the first implementation PR should be **real Search route activation**, not another projection-foundation detour.

### Correction C — Manual detail action must reuse the queue path, but it should not depend on `QueueViewModel`
The truth-preserving action path is still the existing queue/admission boundary. That part of the base doc is right.

But the detail feature should not be wired by reaching sideways into `QueueViewModel`. That would create unnecessary UI-layer coupling.

**Preferred approach:**

- inject `QueueCapturedScanUseCase`
- trigger `AutoFlushCoordinator` after a successful local enqueue, to preserve existing post-enqueue behavior

### Correction D — Scan advisory is not a simple presenter-only change
This is the biggest trap.

`ScanCapturePipeline` currently calls `queueCapturedScan.enqueue(...)`, but throws away the returned `QueueCreationResult` and emits only a generic `CaptureHandoffResult.Accepted` / `SuppressedByCooldown` / `Failed(reason)` result. That means the scan UI currently does **not** have the normalized ticket code or queue creation result it would need to perform a reliable local advisory lookup.

So scan advisory must first enrich the scan handoff boundary with enough information to perform a local attendee lookup truthfully.

---

## 3. Repo grounding this plan assumes

This plan is written against the repo as it exists now.

### Current truths

- `AppShellDestination` already includes `Search`
- `AuthenticatedShellScreen` still renders `SearchStubScreen` for that destination
- `CurrentAttendeeLookupRepository` already provides ranked local search and detail observation
- `AttendeeLookupDao` already supports exact ticket, ticket prefix, and name/email matching
- `AttendeeSearchRecord` and `AttendeeDetailRecord` already exist
- `ScanningViewModel` still reports accepted captures as `Queued locally (pending upload)`
- `ScanCapturePipeline` currently drops the returned `QueueCreationResult` and only emits a generic handoff result
- `DefaultQueueCapturedScanUseCase` already normalizes ticket codes and returns `QueueCreationResult`

### Existing files this priority must respect

- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/app/MainActivity.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/app/navigation/AppShellDestination.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/app/shell/AuthenticatedShellScreen.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/data/local/AttendeeEntity.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/data/local/AttendeeLookupDao.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/data/repository/CurrentAttendeeLookupRepository.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/domain/model/AttendeeSearchRecord.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/domain/model/AttendeeDetailRecord.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/domain/usecase/DefaultQueueCapturedScanUseCase.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/scanning/usecase/ScanCapturePipeline.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/scanning/usecase/CaptureHandoffResult.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/scanning/ui/ScanningViewModel.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/scanning/screen/ScanDestinationRoute.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/scanning/screen/ScanDestinationPresenter.kt`

---

## 4. Non-negotiable truth rules

These are not optional. Codex must preserve them in all PRs.

### Rule 1
Queued locally is **not** server-confirmed admission.

### Rule 2
Local attendee lookup is **advisory local cache truth** and may be stale.

### Rule 3
Manual operator action must reuse the existing queue/admission path.

### Rule 4
Search is operator-facing, not admin-facing.

### Rule 5
Scan remains the primary workflow. Search is the fallback/recovery workflow.

### Rule 6
“Not found locally” is **not** the same as “invalid ticket.”

### Rule 7
No new backend routes, no remote search, no direct manual check-in API.

---

## 5. Ultimate goal

A gate operator can move from scan uncertainty to a truthful next action in a few seconds, entirely inside the app.

That means:

1. scan remains fast
2. local attendee context becomes easy to access
3. attendee detail is available when needed
4. manual fallback action uses the existing local queue path
5. the app never confuses:
   - local cache truth
   - queued-local truth
   - server-confirmed truth

---

## 6. Exact PR split

This priority should be implemented in **five PRs**.

Do **not** collapse these into one or two large PRs.

| PR | Branch | PR Title | Depends On | Purpose |
|---|---|---|---|---|
| PR 1 | `codex/p1-search-destination-shell` | `[codex] p1 search destination shell` | `main` | Replace the Search stub with a real local Search destination. |
| PR 2 | `codex/p1-search-attendee-detail` | `[codex] p1 search attendee detail` | PR 1 | Add attendee detail routing and read-only detail UI under Search. |
| PR 3 | `codex/p1-manual-detail-queue-action` | `[codex] p1 manual detail queue action` | PR 2 | Add manual intervention from attendee detail through the existing queue path. |
| PR 4 | `codex/p1-scan-local-advisory` | `[codex] p1 scan local advisory` | PR 3 | Add compact scan-time local advisory using the same attendee truth model. |
| PR 5 | `codex/p1-truth-locks-and-docs` | `[codex] p1 truth locks and docs` | PR 4 | Lock wording, truth semantics, and operator policy with focused tests and docs. |

---

## 7. Worktree setup

Create one worktree per PR.

```bash
git fetch origin
git worktree add ../fastcheck-p1-pr1 -b codex/p1-search-destination-shell origin/main
git worktree add ../fastcheck-p1-pr2 -b codex/p1-search-attendee-detail origin/main
git worktree add ../fastcheck-p1-pr3 -b codex/p1-manual-detail-queue-action origin/main
git worktree add ../fastcheck-p1-pr4 -b codex/p1-scan-local-advisory origin/main
git worktree add ../fastcheck-p1-pr5 -b codex/p1-truth-locks-and-docs origin/main
```

Use a normal stacked flow:

- PR 1 from `main`
- PR 2 from PR 1 branch tip
- PR 3 from PR 2 branch tip
- PR 4 from PR 3 branch tip
- PR 5 from PR 4 branch tip

Do not branch all five off `main` and then hand-wave the merge conflicts later.

---

## 8. Recommended folder structure for this priority

```text
android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/
  feature/
    search/
      SearchDestinationRoute.kt
      SearchViewModel.kt
      SearchDestinationPresenter.kt
      SearchDestinationScreen.kt
      model/
        SearchUiState.kt
      detail/
        AttendeeDetailRoute.kt
        AttendeeDetailViewModel.kt
        AttendeeDetailPresenter.kt
        AttendeeDetailScreen.kt
        model/
          AttendeeDetailUiState.kt
          ManualActionUiState.kt
```

### Why this structure

- matches the existing shell destination name: `Search`
- keeps detail tightly scoped under Search
- avoids introducing a broader `feature/attendees/` surface prematurely
- keeps operator flow boundaries obvious

---

# 9. PR 1 — Search destination shell

## 9.1 Goal

Replace the Search stub with a real operator-facing local Search workflow.

## 9.2 Why this PR comes first

Because the shell already exposes a Search destination, and the local lookup plumbing already exists. This is the fastest route to immediate operator value.

## 9.3 Scope

### Create

- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/search/SearchDestinationRoute.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/search/SearchViewModel.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/search/SearchDestinationPresenter.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/search/SearchDestinationScreen.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/search/model/SearchUiState.kt`
- `android/scanner-app/app/src/test/java/za/co/voelgoed/fastcheck/feature/search/SearchViewModelTest.kt`
- `android/scanner-app/app/src/test/java/za/co/voelgoed/fastcheck/feature/search/SearchDestinationPresenterTest.kt`

### Update

- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/app/MainActivity.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/app/shell/AuthenticatedShellScreen.kt`

## 9.4 Exact implementation requirements

### MainActivity

Add:

- `private val searchViewModel: SearchViewModel by viewModels()`
- a `searchContent = { ... }` slot when building `AuthenticatedShellScreen`
- `SearchDestinationRoute(session = authenticatedSession, searchViewModel = searchViewModel)` when authenticated

### AuthenticatedShellScreen

Change the function signature to accept:

- `searchContent: @Composable () -> Unit`

Replace:

- `AppShellDestination.Search -> SearchStubScreen(...)`

With:

- `AppShellDestination.Search -> searchContent()`

Do **not** redesign the shell. This is a targeted slot replacement only.

### SearchViewModel

Responsibilities:

- hold query text
- observe current authenticated event context through the passed session
- call local search only
- emit UI state for:
  - empty query
  - searching / stable local results
  - no results
  - results list
- support row selection callback state, but do not implement detail UI yet

### SearchDestinationPresenter

Responsibilities:

- map `AttendeeSearchRecord` to calm, operator-facing result rows
- expose local-cache wording
- rank display emphasis, not ranking logic itself

### SearchDestinationScreen

Must provide:

- query input
- results list
- empty state
- no-result state
- local-cache truth hint

Must **not** provide:

- manual check-in button
- diagnostics/admin controls
- full attendee dump on blank query

## 9.5 Constraints

- local-only search
- current authenticated event only
- empty query returns empty results
- exact ticket match ranks highest, then prefix, then name/email
- no server calls
- no attendee detail yet
- no shell redesign

## 9.6 Edge cases

- blank query after whitespace trim
- mixed-case email/name query
- ticket format needing normalization
- large local event caches — still limit result count
- switching event/session while Search tab is visible

## 9.7 Acceptance criteria

- Search tab is no longer a stub
- operator can search local attendees by ticket/name/email
- exact ticket match behavior remains strongest
- no result dump on blank input
- result language stays local-cache truthful

## 9.8 PR 1 tests

Must cover:

- blank query -> no results
- exact ticket match ordering
- prefix ticket match ordering
- name/email result handling
- authenticated event scoping
- no backend / remote search path introduced

## 9.9 Out of scope

- attendee detail screen
- manual operator action
- scan advisory
- truth-lock docs/tests beyond what is required for PR-level correctness

## 9.10 TOON prompt — PR 1

| Field | Content |
|---|---|
| Task | Replace the Search stub in the authenticated shell with a real local Search destination under `feature/search/` backed by `CurrentAttendeeLookupRepository`. |
| Objective | Turn already-built local attendee lookup infrastructure into a usable operator workflow without changing backend contracts or shell architecture. |
| Output | Create `feature/search/SearchDestinationRoute.kt`, `SearchViewModel.kt`, `SearchDestinationPresenter.kt`, `SearchDestinationScreen.kt`, `model/SearchUiState.kt`; update `app/MainActivity.kt` and `app/shell/AuthenticatedShellScreen.kt`; add `SearchViewModelTest.kt` and `SearchDestinationPresenterTest.kt`. |
| Note | Use `feature/search/`, not `feature/attendees/`. Search must be local-only and scoped to the authenticated event. Empty query returns no results. Exact ticket match ranks highest, then ticket prefix, then name/email. Do not invent remote search. Do not add attendee detail or manual action in this PR. Keep the shell change to a slot replacement only. |

---

# 10. PR 2 — Search attendee detail

## 10.1 Goal

Add a read-only attendee detail route inside the Search feature.

## 10.2 Why this PR comes second

Because result selection needs a proper landing surface before any operator action is allowed.

## 10.3 Scope

### Create

- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/search/detail/AttendeeDetailRoute.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/search/detail/AttendeeDetailViewModel.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/search/detail/AttendeeDetailPresenter.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/search/detail/AttendeeDetailScreen.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/search/detail/model/AttendeeDetailUiState.kt`
- `android/scanner-app/app/src/test/java/za/co/voelgoed/fastcheck/feature/search/detail/AttendeeDetailViewModelTest.kt`
- `android/scanner-app/app/src/test/java/za/co/voelgoed/fastcheck/feature/search/detail/AttendeeDetailPresenterTest.kt`

### Update

- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/search/SearchDestinationRoute.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/search/SearchViewModel.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/search/SearchDestinationScreen.kt`

## 10.4 Exact implementation requirements

### Search route structure

Keep Search self-contained.

The Search feature should own its own internal selection/detail state. Do **not** promote attendee detail into shell navigation.

Preferred flow:

- Search list remains the main Search content
- selecting a result switches Search feature state into detail mode
- detail has an in-feature back action to return to results

### AttendeeDetailViewModel

Responsibilities:

- observe one attendee detail by `eventId + attendeeId`
- expose loading/available/not-found states
- remain read-only in this PR

### AttendeeDetailPresenter

Responsibilities:

- map `AttendeeDetailRecord` into a readable operator detail state
- preserve local-cache wording
- render missing fields calmly, not as fake states

### AttendeeDetailScreen

Show:

- display name
- ticket code
- email if present
- ticket type if present
- payment status if present
- currently inside
- allowed check-ins
- check-ins remaining
- checked-in/out timestamps when present
- local-cache truth note

Do **not** show:

- manual action button yet
- diagnostics/admin controls
- server-confirmed language

## 10.5 Constraints

- read-only only
- fields shown must exist locally
- no fake backend truth
- no shell routing redesign
- no manual action yet

## 10.6 Edge cases

- missing email
- missing timestamps
- attendee disappears from local cache while detail is open
- event change invalidates prior selection
- selected attendee id no longer belongs to current event

## 10.7 Acceptance criteria

- tapping a search result opens a proper attendee detail surface
- detail reflects only local cached truth
- missing fields are handled cleanly
- no action button yet

## 10.8 PR 2 tests

Must cover:

- detail loading and available states
- null timestamps
- missing email
- inside/check-in count rendering
- event scoping
- wording remains advisory local-cache truth

## 10.9 Out of scope

- manual check-in/manual scan action
- scan advisory
- cross-feature operator actions

## 10.10 TOON prompt — PR 2

| Field | Content |
|---|---|
| Task | Add a read-only attendee detail route under `feature/search/detail/` and wire Search result selection to it without changing shell navigation. |
| Objective | Give operators a truthful inspection surface for one attendee before any action is allowed. |
| Output | Create `feature/search/detail/AttendeeDetailRoute.kt`, `AttendeeDetailViewModel.kt`, `AttendeeDetailPresenter.kt`, `AttendeeDetailScreen.kt`, `model/AttendeeDetailUiState.kt`; update Search route/screen/viewmodel selection flow; add focused detail tests. |
| Note | Reuse `CurrentAttendeeLookupRepository.observeDetail(...)`. Keep Search self-contained; do not move attendee detail into shell navigation. This PR is read-only only. Show only fields that exist locally. Preserve “local attendee cache” truth boundaries. |

---

# 11. PR 3 — Manual detail queue action

## 11.1 Goal

Add a one-tap manual operator action from attendee detail using the existing local queue path.

## 11.2 Why this PR comes third

Because the operator first needs a truthful detail view before action is introduced.

## 11.3 Scope

### Create

- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/search/detail/model/ManualActionUiState.kt`
- `android/scanner-app/app/src/test/java/za/co/voelgoed/fastcheck/feature/search/detail/AttendeeDetailManualActionTest.kt`

### Update

- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/search/detail/AttendeeDetailViewModel.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/search/detail/AttendeeDetailPresenter.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/search/detail/AttendeeDetailScreen.kt`

## 11.4 Exact implementation requirements

### Action path

Reuse the existing queue/admission boundary.

Preferred implementation:

- inject `QueueCapturedScanUseCase`
- inject `AutoFlushCoordinator`
- on successful local enqueue, trigger `AutoFlushTrigger.AfterEnqueue`

Avoid using `QueueViewModel` from inside Search/detail.

### Manual action behavior

- action is **IN-only**
- use the attendee detail ticket code, not a free-form text input
- use current session/operator context as existing queue path does
- feedback must remain local-queue truthful

### Feedback states

Support at minimum:

- queued locally / pending upload
- invalid ticket code
- missing session context
- replay suppressed
- generic failure

### UI rules

- button should be visible only when the detail record is available
- while action is in progress, prevent repeated rapid taps
- after completion, show calm, explicit local-queue feedback

## 11.5 Constraints

- no new network endpoint
- no direct backend call
- no “admitted” or “checked in” success wording on local enqueue alone
- no widening into Event/Support work

## 11.6 Edge cases

- missing current session context
- operator taps repeatedly
- auth expires after local enqueue but before flush
- local replay suppression blocks duplicate detail action
- ticket normalization fails unexpectedly

## 11.7 Acceptance criteria

- operator can trigger manual action from attendee detail
- action uses existing queue/admission path only
- successful local action still says queued locally / pending upload
- repeated taps do not create chaos

## 11.8 PR 3 tests

Must cover:

- queue use case invoked with the detail ticket code
- auto flush requested only after successful enqueue
- replay suppressed path
- invalid ticket path
- missing session context path
- wording truth stays local, not backend-confirmed

## 11.9 Out of scope

- scan-time advisory
- broad support/diagnostics changes
- supervisor tools

## 11.10 TOON prompt — PR 3

| Field | Content |
|---|---|
| Task | Add a manual operator action to attendee detail that reuses the existing queue/admission path and triggers normal post-enqueue flush behavior. |
| Objective | Give gate staff a truthful one-tap fallback action without inventing a second admission system or coupling Search to `QueueViewModel`. |
| Output | Update attendee detail viewmodel/presenter/screen, add `model/ManualActionUiState.kt`, and add focused manual-action tests. |
| Note | Inject `QueueCapturedScanUseCase` and `AutoFlushCoordinator`; do not depend on `QueueViewModel` from Search/detail. Action is IN-only and uses the attendee detail ticket code. Feedback must remain “queued locally / pending upload” when successful locally. Respect replay suppression, invalid ticket normalization, missing session context, and repeated taps. No direct network calls. |

---

# 12. PR 4 — Scan local advisory

## 12.1 Goal

Add compact scan-time local attendee advisory using the same truth model that powers Search/detail.

## 12.2 Why this PR comes fourth

Because scan advisory should reuse the same attendee truth model the operator can already inspect in Search/detail.

## 12.3 Critical implementation warning

This PR is **not** just a presenter tweak.

`ScanCapturePipeline` currently discards the returned `QueueCreationResult` from `queueCapturedScan.enqueue(...)` and emits only a generic `CaptureHandoffResult.Accepted` result. That is not enough information to perform a truthful attendee lookup or advisory mapping.

So this PR must first enrich the scan handoff boundary.

## 12.4 Scope

### Create

- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/scanning/ui/model/ScanAdvisoryState.kt`
- `android/scanner-app/app/src/test/java/za/co/voelgoed/fastcheck/feature/scanning/ui/ScanningViewModelAdvisoryTest.kt`
- `android/scanner-app/app/src/test/java/za/co/voelgoed/fastcheck/feature/scanning/screen/ScanDestinationPresenterAdvisoryTest.kt`

### Update

- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/scanning/usecase/CaptureHandoffResult.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/scanning/usecase/ScanCapturePipeline.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/scanning/ui/ScanningViewModel.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/scanning/ui/ScanningUiState.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/scanning/screen/ScanDestinationPresenter.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/scanning/screen/ScanDestinationUiState.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/scanning/screen/ScanDestinationScreen.kt`

## 12.5 Exact implementation requirements

### Step 1 — Enrich handoff result

Refactor `CaptureHandoffResult` so accepted local handoff can carry enough information for advisory lookup.

Minimum acceptable payload for the accepted path:

- canonical ticket code
- queue creation result or equivalent accepted local truth

Do **not** throw away the local queue result anymore.

### Step 2 — Lookup local attendee truth

After a locally accepted capture:

- perform a local attendee lookup using the canonical ticket code and current event context
- derive a compact advisory state

Possible advisory states:

- found locally
- already inside
- no check-ins remaining
- not found locally
- lookup unavailable

### Step 3 — Keep queue truth primary

The scan surface must still primarily show local queue truth.

The advisory must be clearly secondary.

For example:

- primary: `Queued locally (pending upload)`
- secondary: `Local attendee cache: already inside`

### Step 4 — Keep scan fast

Do not turn the scan screen into Search.

The advisory should be:

- small
- fast
- dismissible or short-lived if needed
- not a large extra card stack

## 12.6 Constraints

- queueing remains primary scan outcome
- local advisory remains secondary
- not found locally != invalid ticket
- no backend lookup
- no scan loop slowdown from wasteful queries

## 12.7 Edge cases

- accepted local queue but attendee not yet in local cache
- replay-suppressed captures
- invalid ticket normalization
- stale event context
- multiple rapid captures replacing advisory state
- local lookup temporarily unavailable

## 12.8 Acceptance criteria

- scan flow can show compact local attendee guidance after accepted handoff
- queue truth remains primary
- advisory wording stays explicitly local-cache-based
- scan loop remains fast and uncluttered

## 12.9 PR 4 tests

Must cover:

- accepted local handoff carries enough data for lookup
- already-inside advisory
- no-checkins-remaining advisory
- not-found-locally advisory
- replay-suppressed path does not show fake attendee advisory
- queue truth remains primary in presenter output

## 12.10 Out of scope

- turning Scan into full attendee detail
- support screen work
- broader queue semantics rewrite

## 12.11 TOON prompt — PR 4

| Field | Content |
|---|---|
| Task | Add compact local attendee advisory to the Scan workflow by first enriching the scan handoff result so the UI has the canonical ticket code and local queue outcome needed for advisory lookup. |
| Objective | Improve scan-time operator confidence without replacing queue truth or inventing a backend validation path. |
| Output | Update `CaptureHandoffResult.kt`, `ScanCapturePipeline.kt`, `ScanningViewModel.kt`, relevant scan UI state/screen files, and add advisory-specific tests. |
| Note | This is not just a presenter change. `ScanCapturePipeline` currently throws away `QueueCreationResult`; fix that first. Queueing remains the primary scan outcome. Advisory is secondary and local-cache-based only. “Not found locally” is not “invalid ticket.” Do not slow the scan loop or turn Scan into Search. |

---

# 13. PR 5 — Truth locks and docs

## 13.1 Goal

Lock the wording, truth semantics, and operator workflow so Priority 1 does not regress later.

## 13.2 Why this PR comes last

Because truth-locks are only meaningful once Search, detail, manual action, and scan advisory are all in place.

## 13.3 Scope

### Create

- `android/scanner-app/app/src/test/java/za/co/voelgoed/fastcheck/feature/search/SearchTruthLockTest.kt`
- `android/scanner-app/app/src/test/java/za/co/voelgoed/fastcheck/feature/search/detail/ManualActionTruthLockTest.kt`
- `android/scanner-app/app/src/test/java/za/co/voelgoed/fastcheck/feature/scanning/ScanAdvisoryTruthLockTest.kt`

### Update

- `android/scanner-app/docs/runtime_truth_lockdown.md`
- `docs/development/phase-11-attendee-search-and-manual-checkin-foundation.md`
- any presenter/viewmodel tests that need final wording stabilization

## 13.4 Exact implementation requirements

### Docs

Update docs so the repo no longer points Codex toward stale assumptions.

The existing Phase 11 doc should be corrected to reflect:

- `feature/search/` rather than `feature/attendees/`
- projection foundation already exists
- actual implementation order is Search -> detail -> manual action -> scan advisory -> truth locks

### Tests

Add focused truth-lock tests for:

- Search wording
- attendee detail wording
- manual queue-action wording
- scan advisory wording

These tests should lock semantics, not pixel layout.

## 13.5 Constraints

- no screenshot testing
- no bloated UI harness work
- keep tests fast and deterministic
- update docs to the repo truth as it now exists

## 13.6 Acceptance criteria

- docs and code agree on local-cache vs queued-local vs server-confirmed truth
- the stale `feature/attendees/` direction is removed from active planning docs
- wording drift becomes harder to reintroduce accidentally

## 13.7 PR 5 tests

Must cover:

- `queued locally` wording boundaries
- `local attendee cache` wording boundaries
- no backend-confirmed language leaking into Search/detail/manual local action/advisory

## 13.8 Out of scope

- new feature behavior beyond wording/doc stabilization
- support or Event expansions

## 13.9 TOON prompt — PR 5

| Field | Content |
|---|---|
| Task | Add truth-lock tests and doc updates for Search, attendee detail, manual detail action, and scan advisory so Priority 1 semantics cannot drift back into false backend claims. |
| Objective | Prevent future regressions that blur local attendee cache truth, queued-local truth, and server-confirmed truth. |
| Output | Add focused truth-lock tests, update `android/scanner-app/docs/runtime_truth_lockdown.md`, and correct `docs/development/phase-11-attendee-search-and-manual-checkin-foundation.md` to match the implemented repo direction. |
| Note | Lock wording and state semantics, not visual layout. Remove stale planning assumptions such as `feature/attendees/` and projection-foundation-first ordering. Keep tests narrow, deterministic, and grounded in actual operator truth. |

---

## 14. Validation commands for every PR

Run after each PR slice.

```bash
git diff --check
JAVA_HOME=/home/jcschoeman96/.jdks/jdk-25.0.2+10 bash ./gradlew -Dorg.gradle.java.home=/home/jcschoeman96/.jdks/jdk-25.0.2+10 :app:compileDebugKotlin :app:testDebugUnitTest
```

If a PR introduces Room schema changes, add the relevant migration/instrumentation tests. Priority 1 should not need schema churn if implemented correctly.

---

## 15. What Codex must not do

Reject the PR if Codex does any of this:

- creates `feature/attendees/` for this priority instead of `feature/search/`
- invents a backend search endpoint
- invents a direct manual check-in API
- treats local attendee match as backend admission truth
- makes Search into an admin/debug console
- redesigns shell navigation beyond the minimal Search slot activation
- couples Search/detail to `QueueViewModel`
- adds scan advisory without first enriching the handoff result
- treats “not found locally” as “invalid ticket”
- broadens into Event/Support implementation work in these PRs

---

## 16. What success looks like

Priority 1 succeeds when:

- Search is a real destination, not a stub
- operators can search local attendees quickly
- operators can open attendee detail and trust what they see
- manual fallback action uses the existing queue path and stays truthful
- scan flow can show compact local attendee guidance without replacing queue truth
- the repo clearly preserves the difference between:
  - local attendee cache truth
  - queued-local truth
  - server-confirmed truth

That is the correct production-facing shape for this priority.
