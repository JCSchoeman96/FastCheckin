# Phase 11 — Attendee Search and Manual Check-In Foundation

## Phase / Plan Description

Phase 11 turns attendee search and manual intervention into a first-class operator workflow **without inventing new backend APIs** and without violating the current Android architecture.

This phase is rooted in the current repo reality:

- Android runtime contract is still limited to:
  - `POST /api/v1/mobile/login`
  - `GET /api/v1/mobile/attendees`
  - `POST /api/v1/mobile/scans`
- Android remains local-first and backend-authoritative.
- Queueing and upload stay outside scanner/search UI code.
- Manual flush remains fallback/debug, not the center of the operator workflow.
- The local attendee cache is richer than the current `AttendeeRecord` domain projection:
  - `AttendeeEntity` already stores `firstName`, `lastName`, `email`, `allowedCheckins`, and `checkinsRemaining`
  - but `AttendeeEntity.toDomain()` currently collapses that down to `fullName`, ticket/payment, inside-state, and timestamp only
- The existing queue path already provides the honest manual-action route:
  - `QueueCapturedScanUseCase.enqueue(...)`
  - this means manual check-in should be designed as a productized operator workflow over the existing local queue/admission path, **not** as a new invented backend action

This phase should therefore do three things:

1. restore and expose the right attendee information to the Android-side search/detail workflow
2. create a proper Search/manual check-in feature foundation
3. preserve the truthful local-queue vs server-confirmed distinction

## What the Phase Touches

This phase is expected to touch work in and around:

- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/domain/model/`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/data/mapper/`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/data/local/`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/data/repository/`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/attendees/` **(new)**
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/core/designsystem/semantic/` **only if projection helpers need extension**
- shell/runtime integration points introduced in Phases 9–10 for the Search destination only

Likely existing repo anchors this phase must respect:

- `feature.auth.*`
- `feature.scanning.*`
- `feature.queue.*`
- `feature.sync.*`
- `feature.diagnostics.*`
- `domain/usecase/QueueCapturedScanUseCase.kt`
- `data/mapper/AttendeeMappers.kt`
- `data/local/AttendeeEntity.kt`
- `domain/model/AttendeeRecord.kt`

## What Success Looks Like — End Goal for the Phase

At the end of Phase 11:

- the app has a real **Search** destination for operators
- attendee search is performed against the existing local attendee cache, not by inventing a new server search API
- operator can:
  - search attendee locally
  - open a detail view
  - see meaningful operator-facing information
  - trigger a manual check-in / manual scan action through the existing queue/admission path
- manual check-in remains truthful:
  - it is queued locally first
  - it is **not** presented as server-confirmed immediately
- the Android-side attendee projection is rich enough to support search and useful detail presentation
- no new backend routes are required
- no queue/network/domain boundary is violated
- no “fake admin console” behavior leaks back into the main operator workflow

## Constraints

### Architecture constraints
- Respect `android/scanner-app/docs/architecture.md`
- Scanner analysis must never call network directly
- UI/ViewModels remain projection-only over repository/Room/coordinator truth
- Android runtime contract remains limited to login / attendees / scans
- Manual flush remains fallback/debug
- Search/manual check-in must not introduce a new backend check-in endpoint assumption

### Product constraints
- Search is secondary to Scan, but still first-class
- Search/manual check-in must feel operator-facing, not debug-facing
- Do not elevate diagnostics/admin clutter into this workflow
- Keep operator truth calm and explicit:
  - queued locally
  - uploaded / accepted
  - duplicate
  - invalid
  - offline-required
  - failed

### Implementation constraints
- No unrelated Gradle/tooling churn
- No app-shell redesign in this phase
- No broad Event screen implementation yet
- No hardware-scanner expansion in this phase
- Smartphone-first product remains the active priority

## Worktree Creation

Create one worktree per PR.

### PR 11A — attendee projection and query foundation
- Branch: `codex/phase11-attendee-projection-foundation`
- PR title: `[codex] phase 11 attendee projection foundation`

### PR 11B — search destination scaffold
- Branch: `codex/phase11-search-destination`
- PR title: `[codex] phase 11 search destination`

### PR 11C — attendee details and manual check-in
- Branch: `codex/phase11-attendee-details-manual-checkin`
- PR title: `[codex] phase 11 attendee details and manual check-in`

Example worktree commands:

```bash
git fetch origin
git worktree add ../fastcheck-phase11a -b codex/phase11-attendee-projection-foundation origin/main
git worktree add ../fastcheck-phase11b -b codex/phase11-search-destination origin/main
git worktree add ../fastcheck-phase11c -b codex/phase11-attendee-details-manual-checkin origin/main
```

---

# Detailed Prompts / Tasks / Plans

## PR 11A — Attendee Projection and Query Foundation

### What this PR is
Restore and formalize the Android-side attendee projection/search foundation so the app can support real Search and detail views from the existing synced attendee cache.

### Why this PR comes first
The local Room entity is already richer than the current domain record. Search/manual check-in should not be built on a lossy projection.

### What this PR touches
- `domain/model/AttendeeRecord.kt` or a new attendee-search/detail projection model
- `data/mapper/AttendeeMappers.kt`
- Room/local query support needed for local attendee search
- repository interfaces/adapters only where required to expose local attendee lookup/search truth
- tests for projection/query behavior

### What success looks like
- Android-side attendee/search projection includes enough information for:
  - display name
  - ticket code
  - email if present
  - ticket type
  - payment summary
  - current inside/check-in availability cues
  - check-in allowance / remaining if supported from local data
- local search foundation exists over synced attendee data
- no server API expansion is introduced
- no queue/manual-check-in UI yet

### Constraints
- Do not invent `checkedInAt` / `checkedOutAt` data if Android does not have it
- If the current semantic attendance mapping requires richer data than Android has, document and project only what is truthful
- Keep repository additions narrow and local-cache grounded
- Do not create a broad admin/reporting repository in this phase

### Detailed prompt
| Field | Content |
|---|---|
| Task | Implement the attendee projection and local query foundation needed for Search/manual check-in in the Android scanner app. |
| Objective | Stop losing useful synced attendee fields between Room and domain/UI layers, and expose a truthful local attendee query path for the future Search screen. |
| Output | Android-side attendee projection/model updates, mapper updates, local query/repository support for attendee search, and focused tests. |
| Note | Root this work in the current repo only. `AttendeeEntity` already contains first/last name, email, allowed check-ins, and check-ins remaining. `AttendeeEntity.toDomain()` currently drops some of that richness. Preserve architecture boundaries: no new backend routes, no network search, no UI redesign, no manual-check-in UI yet. Separate “what Android can support truthfully now” from “what remains blocked by the current contract/model.” Keep code minimal, clear, and testable. |

### Tests / regression protection
Add focused tests for:
- mapper preserves and exposes required attendee information
- local search query behavior for:
  - exact ticket code
  - partial name
  - email if present
  - empty query behavior
- projection truth for supported attendance/payment fields
- no false implication of server-confirmed check-in status beyond current model support

Recommended validation:
```bash
git diff --check
JAVA_HOME=/home/jcschoeman96/.jdks/jdk-25.0.2+10 bash ./gradlew -Dorg.gradle.java.home=/home/jcschoeman96/.jdks/jdk-25.0.2+10 :app:compileDebugKotlin :app:testDebugUnitTest
```

---

## PR 11B — Search Destination Scaffold

### What this PR is
Create the Search destination as a real product surface over the local attendee cache.

### Why this PR comes second
The screen should consume a stable Android-side attendee/search projection, not force the data model shape itself.

### What this PR touches
- `feature/attendees/` **(new)**
  - search screen state
  - search ViewModel
  - search UI
- authenticated shell integration for the Search destination
- no manual action execution yet beyond navigation/selection

### What success looks like
- Search tab exists in the structured runtime
- operator can search attendees locally
- operator gets a useful result list
- tapping a result can move toward detail flow or selection state
- no fake “live backend search” implied
- no manual-check-in action yet if that would widen scope

### Constraints
- Search must feel fast and local-first
- No direct network calls
- No giant feature surface
- No Event screen work in this PR
- Keep Scan workflow untouched except for shell-level destination integration

### Detailed prompt
| Field | Content |
|---|---|
| Task | Implement the Search destination scaffold for the Android scanner app using the local attendee cache and the attendee projection/query foundation from PR 11A. |
| Objective | Introduce a real operator-facing Search workflow without changing backend contracts or overloading the Scan screen. |
| Output | `feature/attendees/*` files for Search state, ViewModel, and UI, plus the minimal authenticated-shell integration needed for the Search destination. |
| Note | Search must stay local-first and truthful to the current synced attendee cache. Do not invent remote search. Do not add manual check-in action behavior in this PR unless it is required for screen plumbing only. Keep the destination focused: query input, results, selection/navigation. Do not widen into Event screen work or diagnostics. Keep architecture boundaries intact. |

### Tests / regression protection
Add focused tests for:
- Search ViewModel query/state behavior
- empty results
- query updates
- result projection correctness
- shell integration only where testable without bloated UI harness work

Recommended validation:
```bash
git diff --check
JAVA_HOME=/home/jcschoeman96/.jdks/jdk-25.0.2+10 bash ./gradlew -Dorg.gradle.java.home=/home/jcschoeman96/.jdks/jdk-25.0.2+10 :app:compileDebugKotlin :app:testDebugUnitTest
```

---

## PR 11C — Attendee Details and Manual Check-In

### What this PR is
Turn Search into a useful operator intervention workflow by adding attendee details and a manual check-in/manual scan action that reuses the existing queue/admission path.

### Why this PR comes third
Manual action should be built over the final shape of:
- attendee projection
- local search
- existing queue/admission truth

### What this PR touches
- `feature/attendees/` detail UI/state/action wiring
- local/manual operator action path using `QueueCapturedScanUseCase.enqueue(...)`
- semantic feedback presentation for manual action result
- possibly minimal integration with existing queue/scan semantic truth

### What success looks like
- operator can open attendee details
- operator can trigger a manual check-in/manual scan action from that detail surface
- action truth is honest:
  - queued locally first
  - not immediately shown as server-confirmed success
- duplicate/invalid/offline/failure states are surfaced through the existing semantic vocabulary where appropriate
- no new backend endpoint is introduced

### Constraints
- Manual check-in must reuse the existing queueing/admission path, not invent a new network action
- Do not present manual action as a guaranteed success before upload/backend admission
- Do not collapse duplicate semantics into attendance semantics
- Keep manual action calm and operator-clear
- Do not broaden into Event statistics in this PR

### Detailed prompt
| Field | Content |
|---|---|
| Task | Implement attendee detail presentation and manual check-in/manual scan behavior for the Search workflow using the existing local queue/admission path. |
| Objective | Give operators a truthful, operator-facing fallback/intervention workflow without inventing a separate backend check-in system. |
| Output | Attendee detail UI/state/action files under `feature/attendees/*`, manual action wiring through the existing queue use case, and focused tests. |
| Note | Reuse `QueueCapturedScanUseCase.enqueue(...)` as the manual intervention path. Do not invent a new backend check-in API. Keep local-queue vs server-confirmed truth explicit. Surface semantic feedback using the existing design-system semantics where grounded. Do not broaden into event stats or diagnostics. Preserve architecture boundaries: scanner/queue/network/domain behavior must remain cleanly separated. |

### Tests / regression protection
Add focused tests for:
- attendee detail state mapping
- manual action invokes queue use case correctly
- queued-local vs server-confirmed truth is not blurred
- duplicate/invalid/offline/failure feedback cases
- no regression in existing queueing truth or semantic-state expectations

Recommended validation:
```bash
git diff --check
JAVA_HOME=/home/jcschoeman96/.jdks/jdk-25.0.2+10 bash ./gradlew -Dorg.gradle.java.home=/home/jcschoeman96/.jdks/jdk-25.0.2+10 :app:compileDebugKotlin :app:testDebugUnitTest
```

---

# Robust Tests Strategy for the Whole Phase

Phase 11 should not rely on visual confidence alone.

## Must-have test categories
- mapper / projection tests
- local attendee query tests
- Search ViewModel state tests
- attendee detail state tests
- manual queue-action tests
- semantic feedback truth tests

## Explicit regression traps to prevent
- dropping attendee fields again between Room and UI
- inventing a remote search path
- treating manual action as server-confirmed immediately
- collapsing duplicate semantics into generic attendance state
- pushing debug/admin concerns into Search UI
- widening scope into Event screen or shell redesign

## What not to add
- no screenshot tests
- no heavy UI harness churn unless the repo already has a cheap, stable pattern
- no fake backend extensions
- no second manual-action system parallel to queue/admission

---

# Recommended Execution Order

1. PR 11A — attendee projection and query foundation
2. PR 11B — search destination scaffold
3. PR 11C — attendee details and manual check-in

Do not invert that order.

If you build the screen first, the screen will force bad data/model decisions.
If you build manual check-in first, you risk inventing a false backend behavior.

---

# What to Reject from Codex

Push back if Codex:
- invents a new attendee-detail backend route
- invents a dedicated manual check-in network API
- blurs queued-local and uploaded/server-confirmed truth
- moves diagnostics/admin clutter into Search
- expands into Event stats/reporting work
- redesigns shell/navigation beyond the Search destination integration needed
- adds `FcBadge`
- adds hardware-scanner-specific behavior in this phase

---

# End Goal Summary

Phase 11 succeeds when the app can support a **real local-first Search/manual intervention workflow** over the existing attendee sync and queue/admission model.

That means:
- the operator can find the right attendee
- inspect enough useful information
- take a truthful manual action
- and the app still behaves like the same local-first, backend-authoritative scanner product

—not like a second admin console or a fake offline database of truth.
