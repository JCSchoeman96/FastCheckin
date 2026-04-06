# Priority 1 — Local-First Admission Runtime Baseline and Regression Plan

**Status:** Implemented on `origin/main`; this document is the new active Priority 1 baseline  
**Scope:** `android/scanner-app/` only  
**Purpose:** Replace the stale pre-implementation Priority 1 plan with the current repo truth so future coding work does not re-implement, widen, or accidentally regress the local-admission runtime that is now on `main`.

---

## 1. Why this document exists

The old Priority 1 plan was written before the real implementation landed.

That older plan assumed Priority 1 would mostly be:

- activate the Search destination
- add attendee detail
- add manual fallback action
- later add a compact scan advisory

That is no longer the live repo truth.

Current `main` now implements a broader **local-first admission runtime**:

- gate decisions are local-first
- synced attendee rows remain server-synced base truth
- unresolved local admission overlays are the operational truth layer
- accepted local admissions queue reconciliation work for background upload
- Search/detail/manual admit all consume merged local truth
- Event/docs were updated to reflect the same runtime contract

This means Priority 1 should now be treated as:

1. **implemented in substance**
2. **the baseline for all later priorities**
3. **a contract that must be frozen and regression-protected**

This document therefore does **not** tell a coding agent to rebuild Priority 1 from scratch.

It tells the coding agent:

- what shipped
- why it shipped that way
- where the code lives
- what must not be changed casually
- what tests must exist to stop future regression
- what still counts as valid Priority 1 follow-up work

---

## 2. Executive summary

Priority 1 is no longer “Search activation.”

Priority 1 is now:

**A local-first admission runtime for the Android scanner app, with Search/detail/manual-admit and merged Event truth built on top of synced attendee base rows plus unresolved local admission overlays.**

### What shipped

- local admission overlay model
- local-first scan admission boundary
- merged attendee lookup truth
- session-scoped Search destination
- attendee detail
- manual admit from detail
- merged Event truth and docs alignment
- cross-event unresolved-state blocking
- updated architecture/runtime contract docs

### What Priority 1 now means

For future work, Priority 1 is the **contract to preserve**, not a blank feature backlog.

---

## 3. Current runtime contract

The Android scanner app is now explicitly **local-first**.

### Core truth model

#### Server-synced base truth
Lives in attendee rows updated only by attendee sync.

#### Operational gate truth
Lives in unresolved local admission overlays and merged DAO/repository projections.

#### Durable reconciliation truth
Lives in queued scans, persisted flush outcomes, and overlay state transitions.

#### UI truth
ViewModels and presenters must consume merged repository truth. They must not rebuild business truth in the UI layer.

### What this means operationally

- local gate decisions happen without waiting for server round-trips
- accepted local scans create queue + overlay state
- backend upload and later attendee sync reconcile that local work
- flush success alone does **not** clear overlays
- overlays remain active until later sync proves server catch-up
- Search/detail/manual-admit and Event metrics are all downstream of the same merged truth model

---

## 4. Goal

Keep Priority 1 correct, stable, and easy to build on.

That means the coding agent must:

1. preserve the local-first admission model
2. preserve the base-row vs overlay truth split
3. preserve Search/detail/manual-admit operator behavior
4. preserve merged Event truth and docs alignment
5. add or maintain comprehensive regression protection
6. avoid re-planning or re-implementing already-landed work

---

## 5. What shipped in Priority 1

## 5.1 Local-admission runtime foundation

The app now has a true local-admission path instead of a queue-only capture path.

### Main components
- `domain/usecase/AdmitScanUseCase.kt`
- `domain/usecase/DefaultAdmitScanUseCase.kt`
- `data/local/LocalAdmissionOverlayEntity.kt`
- `domain/model/LocalAdmissionDecision.kt`
- `domain/model/LocalAdmissionOverlayState.kt`
- `domain/policy/CurrentEventAdmissionReadiness.kt`
- `data/repository/PaymentStatusRuleMapper.kt`
- `data/repository/OverlayCatchUpPolicy.kt`

### What this runtime does
- normalizes ticket code
- validates current authenticated event context
- checks that the attendee cache is trusted enough for a green decision
- loads attendee from local merged lookup
- blocks conflict / already-inside / no-checkins / blocked payment states
- routes unknown payment or weak-cache cases to manual review
- writes queue + overlay atomically on accepted local admission
- returns explicit accepted / rejected / review-required / operational-failure decisions

## 5.2 Scan flow now uses local admission

### Main components
- `feature/scanning/usecase/ScanCapturePipeline.kt`
- `feature/scanning/usecase/CaptureHandoffResult.kt`
- `feature/scanning/ui/ScanningViewModel.kt`
- `feature/scanning/ui/model/CaptureFeedbackState.kt`

### What changed
- scan capture now flows into `AdmitScanUseCase`
- accepted scan handoff includes attendee/ticket context
- rejected and review-required states are explicit local gate outcomes
- scan no longer behaves like a pure queue-only capture pipe

## 5.3 Search is live, session-scoped, and merged-truth aware

### Main components
- `feature/search/SearchDestinationRoute.kt`
- `feature/search/SearchViewModel.kt`
- `feature/search/SearchDestinationPresenter.kt`
- `feature/search/SearchDestinationScreen.kt`
- `feature/search/model/SearchUiState.kt`

### What changed
- Search is no longer a stub
- Search state is session-scoped
- Search resets on event/session change
- Search can be cleared directly in UI
- results reflect merged local truth rather than raw attendee rows only

## 5.4 Attendee detail and manual admit are live

### Main components
- `feature/search/detail/AttendeeDetailPresenter.kt`
- `feature/search/detail/AttendeeDetailScreen.kt`
- `feature/search/detail/model/AttendeeDetailUiState.kt`
- `feature/search/detail/model/ManualActionUiState.kt`

### What changed
- result selection opens attendee detail in-feature
- detail exposes merged local truth
- detail can perform manual admit through the same local admit path
- manual admit triggers autoflush after successful local enqueue
- detail surfaces accepted / invalid / review / failure feedback explicitly

## 5.5 Event/docs now reflect merged operational truth

### Main components
- `feature/event/EventDestinationPresenter.kt`
- `feature/event/EventDestinationRoute.kt`
- `android/scanner-app/docs/architecture.md`

### What changed
- Event now reports merged local gate truth rather than raw attendee-sync totals alone
- unresolved conflicts and active overlays are explicit event metrics
- architecture docs now describe Android as local-first and define the truth model clearly

## 5.6 Cross-event unresolved-state blocking already moved forward

This is important because it changes later priorities too.

### Main components
- `data/repository/UnresolvedAdmissionStateGate.kt`
- `data/repository/CurrentPhoenixSessionRepository.kt`
- `app/session/SessionGateViewModel.kt`

### What changed
- the app blocks opening a different event when unresolved local state exists for another event
- this guard already moved part of old Priority 5 forward

---

## 6. What Priority 1 is **not** anymore

A coding agent must **not** treat Priority 1 as any of the following:

- “turn on Search”
- “add attendee detail from scratch”
- “invent a queue-based manual fallback action”
- “make scan advisory from the old queue truth model”
- “refactor Priority 1 into a different architecture”

That work is already shipped.

---

## 7. Priority 1 boundaries going forward

## 7.1 In scope for any remaining Priority 1 follow-up
Only these categories are still valid under Priority 1:

- bug fixes inside the shipped local-admission runtime
- regression test expansion
- wording/truth-lock tightening
- smoke validation and runbook hardening
- small refactors that clarify the current model without changing it

## 7.2 Out of scope for further Priority 1 work
These belong to later priorities or new defects, not to redoing Priority 1:

- new supervisor tooling
- poison-queue quarantine
- Room `REPLACE` cleanup outside admission-critical correctness if not already directly implicated
- runtime retention / DB-at-rest policy
- broad support/admin console expansion
- backend contract expansion
- re-architecting local-first admission into server-on-critical-path admission

---

## 8. Non-negotiable truth rules

These rules must be preserved by every later priority.

### Rule 1
Android is local-first for gate decisions.

### Rule 2
Synced attendee rows are server-synced **base truth**, not optimistic local gate truth.

### Rule 3
Local admission overlays are the **operational truth layer** until reconciliation catch-up is proven.

### Rule 4
Flush success does **not** remove overlays immediately.

### Rule 5
Search, attendee detail, manual admit, and Event metrics must consume merged repository truth.

### Rule 6
Queued-local truth is not the same as backend audit/reconciliation truth.

### Rule 7
Conflict overlays are non-admissible until resolved.

### Rule 8
Cross-event session changes must stay guarded while unresolved local state exists.

### Rule 9
UI and presenters must not rebuild business truth that belongs in DAO/repository layers.

### Rule 10
Do not casually widen Priority 1 surfaces into a new admin product.

---

## 9. Folder and file map

This is the concrete current Priority 1 footprint a coding agent must understand before touching anything.

## 9.1 Architecture and docs
- `android/scanner-app/docs/architecture.md`

## 9.2 Session / event guard
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/app/session/SessionGateViewModel.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/data/repository/CurrentPhoenixSessionRepository.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/data/repository/UnresolvedAdmissionStateGate.kt`

## 9.3 Core local-admission runtime
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/domain/usecase/AdmitScanUseCase.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/domain/usecase/DefaultAdmitScanUseCase.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/domain/model/LocalAdmissionDecision.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/domain/model/LocalAdmissionOverlayState.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/domain/policy/AdmissionRuntimePolicy.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/domain/policy/CurrentEventAdmissionReadiness.kt`

## 9.4 Room / merged local truth
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/data/local/LocalAdmissionOverlayEntity.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/data/local/MergedAttendeeLookupProjection.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/data/local/AttendeeLookupDao.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/data/local/EventAttendeeMetricsDao.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/data/local/ScannerDao.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/core/database/FastCheckDatabase.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/core/database/FastCheckDatabaseMigrations.kt`

## 9.5 Repository layer
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/data/repository/AttendeeLookupRepository.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/data/repository/CurrentAttendeeLookupRepository.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/data/repository/CurrentEventAttendeeMetricsRepository.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/data/repository/CurrentPhoenixMobileScanRepository.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/data/repository/CurrentPhoenixSyncRepository.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/data/repository/OverlayCatchUpPolicy.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/data/repository/PaymentStatusRuleMapper.kt`

## 9.6 Scan runtime
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/scanning/usecase/ScanCapturePipeline.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/scanning/usecase/CaptureHandoffResult.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/scanning/ui/ScanningViewModel.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/scanning/ui/ScanningUiState.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/scanning/ui/model/CaptureFeedbackState.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/scanning/screen/ScanDestinationPresenter.kt`

## 9.7 Search/detail/manual admit
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/search/SearchDestinationRoute.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/search/SearchViewModel.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/search/SearchDestinationPresenter.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/search/SearchDestinationScreen.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/search/model/SearchUiState.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/search/detail/AttendeeDetailPresenter.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/search/detail/AttendeeDetailScreen.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/search/detail/model/AttendeeDetailUiState.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/search/detail/model/ManualActionUiState.kt`

## 9.8 Shell wiring
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/app/MainActivity.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/app/shell/AuthenticatedShellScreen.kt`

## 9.9 Event truth surfacing
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/event/EventDestinationRoute.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/event/EventDestinationPresenter.kt`

---

## 10. What the coding agent must do before touching Priority 1 code

Before making any Priority 1-adjacent change, the coding agent must:

1. read `android/scanner-app/docs/architecture.md`
2. inspect the local-admission runtime files
3. confirm whether the change belongs to:
   - Priority 1 bugfix/hardening
   - Priority 2 operator controls
   - Priority 3 quarantine
   - Priority 4 Room write semantics
   - Priority 5 retention/security
4. avoid re-implementing already-landed behavior

If the change proposes to:
- remove overlays
- treat flush success as final overlay cleanup
- bypass merged DAO truth
- wait for server before local gate accept
- reopen cross-event transitions unsafely

then it is wrong unless there is a deliberate architecture review first.

---

## 11. Remaining Priority 1 work

Priority 1 should now be treated as **baseline freeze + regression protection**, not a fresh feature build.

## 11.1 Required follow-up category A — freeze the contract in code and docs
If any docs/tests still describe the old queue-first Search-first plan, update them to the current runtime truth.

## 11.2 Required follow-up category B — expand regression coverage where gaps remain
Later priorities will touch:
- queue behavior
- session behavior
- Support/Event truth
- Room persistence
- runtime retention

That means Priority 1 needs strong regression tests now.

## 11.3 Required follow-up category C — field smoke validation
Real device / operator-loop smoke testing should keep validating:
- same-event re-login continuity
- cross-event blocking
- accepted / invalid / manual-review scan paths
- Search clear / return / detail flow
- overlay persistence through flush success and later sync catch-up

---

## 12. Comprehensive regression test plan

This is the real “what still needs to happen” under Priority 1.

The goal is to make later priorities safe.

## 12.1 Must-have data-layer tests

### Overlay lifecycle
Files:
- `data/repository/OverlayCatchUpPolicy.kt`
- `data/repository/CurrentPhoenixMobileScanRepository.kt`
- `data/repository/CurrentPhoenixSyncRepository.kt`
- `data/local/ScannerDao.kt`

Required tests:
- flush success transitions overlay to `CONFIRMED_LOCAL_UNSYNCED`
- flush success does **not** delete overlay
- later attendee sync deletes overlay only when catch-up rule passes
- contradictory synced timestamps do not clear overlay prematurely
- conflict overlays remain active and non-admissible

### Admission readiness
Files:
- `domain/policy/CurrentEventAdmissionReadiness.kt`

Required tests:
- trusted current-event cache returns true only when current event sync boundary is valid
- stale cache returns false
- wrong-event sync metadata returns false
- missing sync metadata returns false

### Payment mapping
Files:
- `data/repository/PaymentStatusRuleMapper.kt`

Required tests:
- known allowed statuses -> `ALLOWED`
- known blocked statuses -> `BLOCKED`
- unknown statuses -> `UNKNOWN`
- normalization is case-insensitive and deterministic

## 12.2 Must-have admit-use-case tests

Files:
- `domain/usecase/DefaultAdmitScanUseCase.kt`

Required tests:
- invalid ticket normalization -> rejected
- missing session context -> review required
- untrusted cache -> review required
- ticket not found -> rejected
- conflict overlay -> rejected
- already inside -> rejected
- no check-ins remaining -> rejected
- blocked payment -> rejected
- unknown payment -> review required
- successful admit writes queue + overlay and returns accepted
- replay suppression path rejects duplicate local admit safely
- local write failure routes to review required

## 12.3 Must-have DAO / Room tests

Files:
- `data/local/AttendeeLookupDao.kt`
- `data/local/EventAttendeeMetricsDao.kt`
- `data/local/ScannerDao.kt`
- `core/database/FastCheckDatabaseMigrations.kt`

Required tests:
- merged lookup applies overlay truth to attendee search rows
- merged detail applies overlay truth correctly
- event metrics count active overlays and unresolved conflicts correctly
- queue + overlay atomic insert works
- replay suppression is not left behind when queue insert fails
- migration opens and preserves existing queue/runtime shape correctly

## 12.4 Must-have scan runtime tests

Files:
- `feature/scanning/usecase/ScanCapturePipeline.kt`
- `feature/scanning/ui/ScanningViewModel.kt`
- `feature/scanning/screen/ScanDestinationPresenter.kt`

Required tests:
- accepted local admission emits accepted handoff with attendee/ticket context
- rejected path surfaces invalid scan copy
- review-required path surfaces degraded-confidence copy
- cooldown suppression still works
- operational failure stays distinct from rejected/review
- scan UI never claims backend-confirmed admission

## 12.5 Must-have Search/detail/manual-admit tests

Files:
- `feature/search/SearchViewModel.kt`
- `feature/search/SearchDestinationPresenter.kt`
- `feature/search/detail/AttendeeDetailPresenter.kt`

Required tests:
- Search resets on session/event change
- Search clear wipes query + selected detail + manual action state
- blank query stays empty
- result rows reflect merged truth states
- detail reflects merged truth and conflict messaging
- manual admit feedback states are correct for accepted / invalid / review / failure
- auto-flush requested after successful manual admit only

## 12.6 Must-have session/event guard tests

Files:
- `data/repository/CurrentPhoenixSessionRepository.kt`
- `app/session/SessionGateViewModel.kt`

Required tests:
- login to different event is blocked when unresolved foreign event state exists
- restored authenticated session is rejected if unresolved foreign event state exists
- blocking message is surfaced cleanly
- same-event session is not blocked

## 12.7 Must-have Event truth tests

Files:
- `feature/event/EventDestinationPresenter.kt`

Required tests:
- Event metrics consume merged operational truth
- unresolved conflicts show warning banner
- active overlays count is surfaced
- Event wording does not regress to raw queue-only or server-only semantics

---

## 13. Manual smoke test plan

These checks should be run on a real Android environment after any Priority 1-adjacent change.

## 13.1 Green-path admission
- log into a trusted event
- scan a locally valid attendee
- confirm immediate accepted state
- confirm queue/overlay behavior later reconciles without reopening admission

## 13.2 Duplicate / already-inside local block
- scan same attendee again
- confirm invalid scan path
- confirm no false green acceptance

## 13.3 Review-required path
- use stale or untrusted cache scenario
- confirm scan goes to manual review state, not green accept

## 13.4 Search/detail/manual admit
- search attendee
- open detail
- clear search
- repeat with a second attendee
- manual admit from detail
- verify accepted / invalid / review messaging behaves truthfully

## 13.5 Cross-event guard
- retain unresolved queue/overlay state
- attempt login to different event
- confirm login is blocked and message is clear

## 13.6 Overlay catch-up
- create accepted local admission
- flush successfully
- confirm overlay remains
- run later attendee sync
- confirm overlay clears only when catch-up rule is satisfied

---

## 14. Suggested maintenance PR split

Priority 1 does **not** need another large feature PR.

If follow-up work is needed, keep it narrow.

### PR 1A — Priority 1 baseline and truth-lock audit
Focus:
- docs alignment
- wording locks
- missing regression tests

### PR 1B — Priority 1 runtime bugfixes only
Focus:
- fix only defects discovered in smoke tests or regression expansion
- no new feature work

Do not reopen Priority 1 as a multi-PR feature build unless a real defect proves the shipped baseline is wrong.

---

## 15. Coding-agent instructions

### Do
- preserve the local-first runtime contract
- work inside existing files and boundaries first
- add regression tests before broadening behavior
- keep Search/session/detail/manual-admit semantics stable
- treat this doc as the active Priority 1 baseline

### Do not
- re-plan Search as the starting point of Priority 1
- replace overlays with direct attendee-row mutation
- treat flush success as final truth
- move merged truth reconstruction into presenters
- wait for server response to grant normal gate admission
- loosen cross-event guarding
- broaden Priority 1 into a new support/admin product

---

## 16. Acceptance gate for “Priority 1 complete and preserved”

Priority 1 remains complete only if all of the following stay true:

- local gate decisions remain local-first
- base attendee rows remain server-synced truth
- overlays remain operational truth until catch-up
- Search/detail/manual-admit stay functional and truthful
- scan runtime emits accepted / rejected / review-required / failure distinctly
- Event/docs stay aligned with merged local truth
- cross-event unresolved-state blocking stays enforced
- regression tests protect the above

That is the correct current definition of Priority 1.

---

## 17. Short directive for the coding agent

Priority 1 is already shipped on `main`.

Your job is **not** to rebuild it.

Your job is to:

1. preserve the local-first admission runtime
2. add or maintain regression coverage
3. fix only real defects inside the existing boundaries
4. keep later priorities from breaking the shipped contract
