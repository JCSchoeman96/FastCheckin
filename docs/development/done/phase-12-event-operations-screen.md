# Phase 12 — Event Operations Screen

## Phase / Plan Description

Phase 12 turns the future **Event** tab into a clean operational overview for the active event.

This phase is **not** a diagnostics dump, **not** a backend expansion phase, and **not** a control-panel resurrection. It should take the operational truths that already exist in the Android app and project them into a focused Event screen for operators and supervisors.

This phase follows the earlier runtime direction:
- operator priority remains **login and scanning** first
- manual search/check-in remains a separate second workflow
- the Event screen is the third workflow, meant for **event health and operational confidence**
- lower-priority support/debug remains overflow-only

This plan is rooted in the current repo state:
- the Android runtime contract still only includes login / attendees / scans
- manual flush remains fallback/debug, not a primary workflow
- the current diagnostics flow already derives event/session, sync, queue, and flush truth from local and coordinator state
- the current attendee cache is richer in Room than in the current domain projection, which matters for counts and event-health views

Relevant repo anchors:
- `android/scanner-app/docs/architecture.md`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/diagnostics/DiagnosticsViewModel.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/diagnostics/DiagnosticsUiState.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/diagnostics/DiagnosticsUiStateFactory.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/domain/model/AttendeeSyncStatus.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/domain/model/ScannerSession.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/data/local/AttendeeEntity.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/data/mapper/AttendeeMappers.kt`

---

## What the Phase Touches

Phase 12 should touch only the event-operations slice of the runtime.

### Primary touch areas
- new `feature/event/*` package(s)
- event-level UI state / projections
- event-level composables / screens
- local derivation logic for event metrics that are supportable from existing Android truth
- shell wiring for the Event destination, if not already stubbed in Phase 9

### Repo areas likely involved
- `feature/event/*` (new)
- `feature/diagnostics/*` (read-only source for migration/derivation reference, not to remain the final Event screen)
- `data.mapper/*` or a new event-projection mapper layer if needed
- attendee-cache-derived metrics from `data.local.AttendeeEntity`
- shell navigation wiring only as needed to host the Event destination

### Areas this phase must not expand into
- backend contract changes
- scanner pipeline changes
- queue/flush orchestration behavior changes
- manual search/check-in implementation beyond what Event needs for counts
- debug/preferences/logout UX
- broader diagnostics redesign beyond extracting safe ops-facing truths

---

## What Success Looks Like — End Goal for the Phase

At the end of Phase 12, the app should have a proper **Event** destination that answers the operator/supervisor questions:
- What event am I in?
- How many attendees are currently available in local cache?
- What is the current sync health?
- Is there a queue backlog?
- What is the latest upload/flush state?
- Has anything gone operationally wrong that needs attention?

A successful Event screen should feel like:
- a concise operational overview
- trustworthy
- calm
- not cluttered with backend implementation details
- not a debug console

### Minimum target outcomes
- Event screen exists as a first-class destination
- Event screen shows curated ops data, not raw diagnostics
- Event/session identity is clear
- attendee totals are clear
- sync state and queue/flush health are clear
- any manual sync/flush controls remain secondary and justified
- no base URL / API target / token details are elevated into this screen

### Strong outcome
A strong Phase 12 result also includes **derived counts** that help supervisors and operators, but only if they are supportable from current Android truth and labeled honestly.

Examples:
- total attendees synced locally
- currently inside
- remaining check-ins (if supportable from current local model)
- last successful attendee sync
- queue depth
- last flush summary

---

## Constraints

### Architectural constraints
- Respect `android/scanner-app/docs/architecture.md`
- UI/ViewModels remain projection-only over repository/Room/coordinator truth
- scanner analysis must never call network directly
- auto-flush remains the normal upload path; manual flush remains fallback/debug
- do not invent backend APIs beyond login / attendees / scans

### Product constraints
- Event screen is a tertiary workflow, not the main operator workspace
- Event screen must not become a diagnostics dump
- Event screen must not expose low-level environment information to operators by default
- Event screen must not teach operators to babysit sync/flush unless there is a real attention-needed state

### Data/model constraints
- The current Android Room attendee model is richer than the current domain `AttendeeRecord`
- Any event stats derived from attendee data must be grounded in what the app actually stores locally
- If a metric is only approximate or only supportable after Android-side projection/model expansion, the phase must say so explicitly rather than faking precision

### Scope constraints
- no new backend contract
- no new component library work
- no `FcBadge`
- no shell redesign beyond what is necessary to host the Event destination
- no debug/preferences/overflow work in this phase

---

## Repo-Grounded Evaluation

### What Android already knows today
The current diagnostics projection already derives the following from existing truth sources:
- active event identity
- auth/session state
- token state
- last attendee sync time
- attendee count
- local queue depth
- upload state label
- latest flush summary
- server result summary

This comes from `DiagnosticsUiStateFactory`, which combines:
- `ScannerSession`
- token presence
- `AttendeeSyncStatus`
- queue depth
- latest flush report
- semantic `SyncUiState`

That is the strongest existing foundation for the future Event screen.

### What the Event screen should reuse conceptually
The Event screen should reuse the **truth sources**, not the final diagnostics presentation.

In other words:
- use the same durable/session/coordinator truth
- stop surfacing raw diagnostics/admin details as first-class operator content
- create a curated event-ops projection instead

### Important model reality
The attendee cache already stores:
- first name / last name / email
- allowed check-ins
- check-ins remaining
- payment status
- is currently inside
- updatedAt

But the current domain mapper compresses that into a thinner `AttendeeRecord` model.

That means Phase 12 can potentially support better event metrics with Android-side projection work, **without** inventing backend APIs.

This is a key design decision for the phase: derive metrics from existing local truth where possible, and be explicit about what remains blocked or only approximately supportable.

---

## Recommended Phase Split (Separate PRs)

Phase 12 should be broken into separate PRs.

### PR 12A — Event projections and capability-grounded metrics
Build the event-operations projection layer first.

### PR 12B — Event screen UI
Build the Event destination UI on top of the event projection layer.

### PR 12C — Secondary operator controls only if justified
Only if needed after 12A and 12B:
- controlled surfacing of manual sync / manual flush actions
- only if they are clearly secondary and operationally justified

Do **not** start with controls.

---

## Worktree Creation

### PR 12A
- Branch: `codex/phase12-event-projections`
- PR title: `[codex] phase 12 event projections`

### PR 12B
- Branch: `codex/phase12-event-screen`
- PR title: `[codex] phase 12 event screen`

### Optional PR 12C
- Branch: `codex/phase12-event-secondary-controls`
- PR title: `[codex] phase 12 event secondary controls`

---

## Detailed Prompts / Tasks / Plans

## Prompt 12A — Event operations projection layer

| Field | Content |
|---|---|
| Task | Implement the event-operations projection foundation for the future Event screen using current Android truth sources only. |
| Objective | Turn the current diagnostics-oriented operational data into a clean event-focused projection layer that can back the Event destination without exposing raw diagnostics/admin detail. |
| Output | New `feature/event/*` files for event UI state, projection factories/mappers, and any small supporting models needed. |
| Note | Root this in the current repo: `DiagnosticsUiStateFactory`, `DiagnosticsViewModel`, `AttendeeSyncStatus`, `ScannerSession`, queue depth, latest flush report, semantic `SyncUiState`, and locally stored attendee fields from `AttendeeEntity`. Do not invent backend APIs. Do not expose base URL, API target, or token details as Event-screen data. Derive only what is supportable from current Android truth. If some metrics require Android-side projection/model expansion beyond the current `AttendeeRecord`, do that deliberately and minimally, or document them as blocked. Keep the projection operator-facing, not debug-facing. |

### 12A goals
- create an `EventUiState` or equivalent event-ops projection
- define exact event metrics that are supportable now
- separate operator-safe data from diagnostics-only data
- keep labels honest

### 12A likely contents
- `feature/event/EventUiState.kt`
- `feature/event/EventUiStateFactory.kt` or equivalent
- supporting metric models if necessary
- minimal Android-side projection/model improvement if truly required to support better counts

### 12A likely metrics
- current event label
- attendee count
- last sync time
- queue depth
- upload state label
- latest flush summary
- server result summary or a calmer ops-friendly equivalent
- currently inside count if supportable from local truth
- remaining / pending check-in style metrics only if derivable honestly

### 12A non-goals
- UI implementation
- buttons / controls
- diagnostics redesign
- new network calls

---

## Prompt 12B — Event screen UI

| Field | Content |
|---|---|
| Task | Implement the Event destination UI as a clean operational overview screen backed by the Phase 12A projection layer. |
| Objective | Give operators and supervisors a trustworthy event-health view without cluttering the primary scan workflow or surfacing raw diagnostics. |
| Output | `feature/event/*` UI files for the Event destination plus the minimal shell wiring needed to host the screen. |
| Note | Build on the merged design-system foundation (`FastCheckTheme`, semantic states, `FcBanner`, `FcCard`, `FcStatusChip`) but do not add new components. Keep the Event screen concise and operator-facing. Prioritize event identity, attendee totals, queue/sync/flush health, and any supportable attendance counts. Do not elevate debug/admin values such as API base URL or token state into the screen. Do not redesign shell/navigation beyond what is necessary to host the Event destination. |

### 12B recommended layout
Section order should likely be:
1. event identity / high-level status
2. attendee totals / attendance health
3. queue + upload health
4. last sync / last flush summaries
5. optional attention-needed message area

### 12B design guidance
- use `FcCard` for grouping, not diagnostics-like text walls
- use `FcBanner` only for meaningful attention-needed states
- use `FcStatusChip` sparingly for compact state display
- avoid overusing warning colors or creating dashboard noise

### 12B non-goals
- manual search flow
- manual check-in actions
- debug/preferences/logout
- hardware-scanner UX

---

## Prompt 12C — Secondary event controls (only if justified)

| Field | Content |
|---|---|
| Task | Add only the minimum justified secondary controls to the Event screen, such as manual sync or manual flush, if and only if the operational model still needs them visible there. |
| Objective | Preserve operator control for real fallback cases without turning the Event screen into a control panel or teaching users to manage infrastructure constantly. |
| Output | Small Event-screen control additions and any tiny supporting state/wiring needed. |
| Note | This PR is optional. Treat manual sync/flush as secondary, not central. Follow the architecture truth that auto-flush is normal and manual flush is fallback/debug. Do not add controls first. Add them only if the Event screen would otherwise fail practical operational needs. Keep them visually secondary and context-aware. |

### 12C rules
- hide or de-emphasize controls unless justified
- never make flush the main CTA
- never treat sync as equal to scanning
- keep operator mental load low

---

## What Success Looks Like by PR

## PR 12A success
- event metrics are defined from existing truth sources
- unsupported metrics are called out honestly
- debug/admin diagnostics are separated from event ops data
- projection layer is ready for UI

## PR 12B success
- Event destination exists
- screen feels like an operational overview, not diagnostics
- key event health is clear in a few grouped sections
- no raw backend/environment details dominate the screen

## PR 12C success (only if done)
- secondary controls exist only where truly needed
- manual actions remain fallback-oriented
- operator flow remains calm and clear

---

## Robust Tests / Regression Coverage

Phase 12 should include robust projection tests before UI broadening.

## Required tests for 12A
Add focused unit tests for event projection logic:
- event identity formatting
- attendee-count projection
- queue-depth / upload-state projection
- fallback values when session or sync data is missing
- differentiation between operator-safe fields and diagnostics-only fields
- any derived counts (currently inside / remaining / etc.) if implemented

### Good test targets
- `EventUiStateFactoryTest.kt`
- supporting projection mapper tests if helpers are split out

### What to verify
- no invented values when source data is absent
- no debug-only fields leak into the Event screen projection
- sync/flush messaging remains aligned with semantic sync truth
- labels remain truthful when current event and last-synced event differ

## Recommended tests for 12B
Only add UI-facing tests if they are low-cost and already aligned with repo patterns.
Prefer:
- projection-driven tests over visual snapshot churn
- simple Compose/runtime tests only if they materially protect shell wiring or critical screen state behavior

## Do not add
- screenshot tests by default
- broad visual regression harnesses
- brittle tests that snapshot styling instead of meaning

---

## Risks and Edge Cases

### 1. Event counts may be overstated or underspecified
If the app cannot yet derive a supervisor-grade “already checked in / still to check in” metric honestly, do not fake it.

### 2. Diagnostics leakage
There is a strong risk of simply re-skinning diagnostics into the Event screen. Reject that.

### 3. Manual controls creeping forward
Manual sync/flush can easily take over the screen again. Keep them secondary.

### 4. Mismatch between active session and last synced event
This already exists as a possibility in diagnostics projection logic and must remain clearly handled.

### 5. Over-dashboarding
This is a scanner app, not an analytics cockpit. Keep the Event screen concise.

---

## Recommended Execution Order

1. PR 12A — Event projections
2. PR 12B — Event screen
3. Optional PR 12C — Secondary controls only if justified

---

## What to Reject from Codex

Reject or push back if Codex:
- turns the Event screen into a diagnostics dump
- exposes API base URL / API target / token info as first-class event content
- invents backend capabilities beyond login / attendees / scans
- broadens into Search/manual check-in implementation
- makes manual flush or sync a primary CTA
- adds new design-system components
- fakes attendance metrics that current Android truth cannot support
- widens into debug/preferences/logout work

---

## Final End Goal for Phase 12

At the end of Phase 12, the app should have a real **Event** destination that gives a trustworthy operational overview of the active event using current Android truth, while keeping debug/admin details out of the operator’s main path.

This phase succeeds when the Event tab feels like:
- a calm operations overview
- grounded in real local/session/coordinator truth
- aligned with the smartphone-first scanner product
- clearly separate from diagnostics
- ready to support later overflow/admin separation in the next phase
