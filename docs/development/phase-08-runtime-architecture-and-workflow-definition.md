# Phase 8 — Runtime Architecture and Workflow Definition

## Phase / Plan Description

Phase 8 is a **planning and architecture phase**, not a rollout phase.

The purpose of this phase is to define the future runtime shape of the FastCheck Android scanner app as a **structured smartphone-first scanner product**, rooted in the current repository and current runtime constraints.

This phase exists because the design-system foundation is already in place, but the live Android runtime is still shaped like a temporary all-in-one operator/admin shell. The next correct move is not more design-system polish. The next correct move is to define the product runtime structure before implementation continues.

This phase must produce the runtime architecture needed for:

- a clean login/session gate
- an authenticated shell
- a 3-tab bottom navigation structure: **Scan / Search / Event**
- an overflow menu for lower-priority utilities
- a smartphone-first scanner model with explicit battery and camera lifecycle policy
- a clear sync/flush operator policy
- a grounded adoption strategy for moving from the current XML/ViewBinding shell toward the structured product

This phase is documentation and decision-making only. It must not implement runtime changes.

---

## Repo Grounding / Current Reality

This phase must be rooted in the current repo as it exists today.

### Current runtime and architecture reality

The Android runtime currently uses:

- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/app/MainActivity.kt`
- `android/scanner-app/app/src/main/res/layout/activity_main.xml`
- `android/scanner-app/docs/architecture.md`

The current live shell is still one XML/ViewBinding activity that mixes:

- login
- sync
- scanner permission / preview / status
- manual queue and flush controls
- diagnostics and backend-ish operational details

That shell is not the target product shape.

### Current Android runtime contract

The current Android runtime contract remains intentionally narrow:

- `POST /api/v1/mobile/login`
- `GET /api/v1/mobile/attendees`
- `POST /api/v1/mobile/scans`

The Android app must not invent or assume additional mobile APIs during this phase.

### Current operator/product direction

The target product direction for the structured scanner app is:

- **Priority 1:** login and start scanning
- **Priority 2:** manual attendee search / manual check-in / attendee details
- **Priority 3:** event info, totals, sync and queue health
- **Priority 4:** overflow utilities such as preferences, permissions recovery, debug, logout

### Smartphone-first MVP direction

The immediate product is **smartphone-first**.

That means:

- Camera scanning is the MVP path and first priority.
- Battery behavior is a first-class product concern.
- Hardware scanner / DataWedge / alternate scanner-source UX is explicitly deferred until after the smartphone-first runtime is correct.
- Existing source abstractions should be preserved, but the runtime plan must optimize first for smartphone operator use.

---

## What This Phase Touches

This phase is documentation/planning only.

### Files it should create

1. `android/scanner-app/docs/runtime_architecture.md`
2. `android/scanner-app/docs/runtime_data_capability_audit.md`
3. `android/scanner-app/docs/scanner_interaction_policy.md`
4. `android/scanner-app/docs/operator_sync_flush_policy.md`
5. `android/scanner-app/docs/runtime_adoption_strategy.md`

### Files it should inspect and reference

- `android/scanner-app/docs/architecture.md`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/app/MainActivity.kt`
- `android/scanner-app/app/src/main/res/layout/activity_main.xml`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/auth/*`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/scanning/*`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/queue/*`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/sync/*`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/diagnostics/*`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/domain/model/AttendeeRecord.kt`
- existing design-system files under `core/designsystem/*`

### Files it must not change

- runtime Kotlin code
- `activity_main.xml`
- `MainActivity.kt`
- repositories / workers / networking / backend contracts
- design-system component APIs
- any live screen wiring

---

## What Success Looks Like — End Goal for Phase 8

Phase 8 is successful when the repo contains a **clear, implementation-ready runtime plan** that answers all of the following:

1. **What is the target app structure?**
   - unauthenticated login gate
   - authenticated shell
   - bottom-nav destinations
   - overflow responsibilities

2. **What is the operator workflow hierarchy?**
   - Scan first
   - Search/manual check-in second
   - Event operational health third
   - Support/admin utilities in overflow

3. **What is the smartphone-first scanner interaction model?**
   - active vs idle scanner behavior
   - camera lifecycle policy
   - battery policy
   - tab switching policy
   - background/foreground policy

4. **How should sync and flush behave in the product?**
   - mostly automatic
   - clearly surfaced only when needed
   - manual intervention positioned as fallback/debug

5. **What can the future Search and Event screens actually support with the current mobile contract and local model?**
   - what is supported now
   - what requires Android-side model/projection work
   - what is blocked until future backend contract expansion

6. **What is the recommended runtime adoption strategy?**
   - whether XML shell stays temporarily
   - whether authenticated shell is introduced before feature migration
   - where Compose enters first
   - what sequence of implementation phases should follow

7. **What is the next phase after planning?**
   - a narrow implementation phase with explicit boundaries

If the output does not make those decisions clear, the phase is not complete.

---

## Constraints

These are hard rules for Phase 8.

### Runtime and architecture constraints

- No repository / worker / Room / backend contract changes
- No runtime XML/ViewBinding migration in this phase
- No Compose app-shell migration in this phase
- No live runtime implementation in this phase
- No second token system
- No parallel semantic tone enums
- No new components
- No `FcBadge`
- No feature creep into Phase 9 implementation

### Product constraints

- Smartphone camera scanning is the MVP and first priority
- Hardware scanner / DataWedge UX is explicitly deferred to a later phase
- Operator-facing runtime should hide backend/environment details unless needed for support/admin
- Manual flush must stay fallback/debug in policy unless future runtime truth proves otherwise
- Search/Event planning must respect the current mobile contract and current Android data model

### Truth-model constraints

- Scanner analysis must never call network directly
- UI/ViewModels remain projection-only over repository / Room / coordinator truth
- Local queue acceptance must never be presented as server-confirmed admission
- The mobile contract stays limited to login / attendees / scans during this phase

---

## Worktree Creation

Each prompt below is a separate PR and should be handled in its own worktree.

Assuming the main repo root is already checked out and clean:

### PR 8A — Runtime architecture definition

```bash
cd /path/to/FastCheckin

git fetch origin

git worktree add ../FastCheckin-phase8a origin/main -b codex/phase8-runtime-architecture
cd ../FastCheckin-phase8a
```

PR title:

```text
[codex] phase 8 runtime architecture
```

### PR 8B — Domain and data capability audit

```bash
cd /path/to/FastCheckin

git fetch origin

git worktree add ../FastCheckin-phase8b origin/main -b codex/phase8-data-capability-audit
cd ../FastCheckin-phase8b
```

PR title:

```text
[codex] phase 8 data capability audit
```

### PR 8C — Scanner interaction and battery policy

```bash
cd /path/to/FastCheckin

git fetch origin

git worktree add ../FastCheckin-phase8c origin/main -b codex/phase8-scanner-interaction-policy
cd ../FastCheckin-phase8c
```

PR title:

```text
[codex] phase 8 scanner interaction policy
```

### PR 8D — Sync/flush operator policy

```bash
cd /path/to/FastCheckin

git fetch origin

git worktree add ../FastCheckin-phase8d origin/main -b codex/phase8-sync-flush-policy
cd ../FastCheckin-phase8d
```

PR title:

```text
[codex] phase 8 operator sync flush policy
```

### PR 8E — Runtime adoption strategy

```bash
cd /path/to/FastCheckin

git fetch origin

git worktree add ../FastCheckin-phase8e origin/main -b codex/phase8-runtime-adoption-strategy
cd ../FastCheckin-phase8e
```

PR title:

```text
[codex] phase 8 runtime adoption strategy
```

---

## Detailed Prompts / Tasks / Plans

## PR 8A — Runtime Architecture Definition

### What this PR is

This PR defines the future product/runtime structure of the app.

### What it touches

Create:

- `android/scanner-app/docs/runtime_architecture.md`

### End goal for this PR

Document the future runtime structure clearly enough that implementation can begin later without re-debating the app shell.

### Prompt

| Field | Content |
|---|---|
| Task | Create `android/scanner-app/docs/runtime_architecture.md` defining the target product/runtime structure for the FastCheck Android app. |
| Objective | Replace the current all-in-one XML control panel with a clear product architecture centered on login, authenticated shell, bottom navigation, and overflow responsibilities before any implementation begins. |
| Output | `runtime_architecture.md` covering: unauthenticated login gate, authenticated shell, `Scan / Search / Event` bottom-nav destinations, overflow menu responsibilities, screen ownership, lifecycle ownership, and a responsibility split for `MainActivity`. |
| Note | Root this in the current runtime: `MainActivity` currently coordinates auth, sync, diagnostics, queue, scanning, permissions, and autoflush; `activity_main.xml` currently mixes login, sync, scanner, manual queue, and diagnostics in one screen. The target product is smartphone-first. Operators log in with event ID and password only. Do not write code. Do not invent backend capabilities beyond the current mobile contract. State explicitly that the current shell is temporary relative to the target product. |

### What good output should conclude

- Login becomes its own gate.
- The authenticated product shell becomes a separate runtime layer.
- Bottom nav contains Scan, Search, Event.
- Overflow contains preferences, permissions recovery, debug, logout.
- `MainActivity` should stop owning all workflows directly in the future implementation path.

---

## PR 8B — Domain and Data Capability Audit

### What this PR is

This PR determines what the future Search and Event screens can honestly support using the current Android contract and domain model.

### What it touches

Create:

- `android/scanner-app/docs/runtime_data_capability_audit.md`

### End goal for this PR

Stop future implementation from inventing unsupported attendee detail, manual check-in, or event stats behavior.

### Prompt

| Field | Content |
|---|---|
| Task | Create `android/scanner-app/docs/runtime_data_capability_audit.md` mapping the target `Scan`, `Search`, and `Event` screens against the current Android domain model and mobile API contract. |
| Objective | Identify what the structured product can support today from local cache and current endpoints, and what requires Android model expansion or future backend contract work. |
| Output | A capability matrix covering each planned screen and feature: login, scanning, manual search, attendee details, manual check-in, total attendees, checked-in counts, remaining counts, sync health, queue depth, flush summaries. |
| Note | Use the current runtime contract: only login, attendees, scans. Use `AttendeeRecord.kt` as the current Android attendee model. Call out any mismatch between current Android attendee/domain shape and attendance semantics needed by the future Search/Event screens. Do not solve gaps by inventing hidden backend APIs. Separate `supported now`, `supported with Android projection/model work`, and `blocked until contract expansion`. |

### What good output should conclude

At minimum, the audit should answer:

- What can Search do today from local attendee data?
- What attendee detail fields are missing?
- Can the Event screen show total attendees now? Probably yes.
- Can it show checked-in / remaining counts truthfully now? Maybe not fully, depending on current attendee model.
- What manual check-in functionality is possible under the current contract?

---

## PR 8C — Scanner Interaction and Battery Policy

### What this PR is

This PR defines the smartphone-first scanner behavior model.

### What it touches

Create:

- `android/scanner-app/docs/scanner_interaction_policy.md`

### End goal for this PR

Prevent the future Scan screen from inheriting a naive always-on camera model and define a battery-aware scanner interaction policy before implementation.

### Prompt

| Field | Content |
|---|---|
| Task | Create `android/scanner-app/docs/scanner_interaction_policy.md` defining the smartphone-first scanner interaction model and battery policy. |
| Objective | Prevent the future Scan screen from inheriting a naive `camera always on` behavior and define a deliberate scanner session model that is fast, understandable, and battery-aware. |
| Output | A policy doc covering scanner states, camera activation rules, idle / armed / active behavior, inactivity timeout, tab-switch behavior, background/foreground behavior, permission handling, and future hardware-scanner differences. |
| Note | Root this in the current scanner structure: `ScanningViewModel`, `ScanningUiState`, scanner source abstraction, `MainActivity` source binding lifecycle, and camera permission flow. Smartphone camera scanning is MVP priority. Hardware scanner / DataWedge behavior must be deferred and documented as future work, not co-designed as an equal first-class path now. Do not write code. |

### What good output should conclude

A strong policy should define:

- smartphone Scan screen owns camera lifecycle
- camera is not active on non-Scan tabs
- camera is not active in background
- scanner should have explicit idle/armed/active semantics
- queue/sync visibility remains even when camera is idle
- hardware scanner path remains future-safe but deferred

---

## PR 8D — Sync/Flush Operator Policy

### What this PR is

This PR defines what operators should and should not have to think about regarding sync, queue, and flush.

### What it touches

Create:

- `android/scanner-app/docs/operator_sync_flush_policy.md`

### End goal for this PR

Move sync/flush from an operator-managed workflow into a system-managed policy with only the right level of surfacing.

### Prompt

| Field | Content |
|---|---|
| Task | Create `android/scanner-app/docs/operator_sync_flush_policy.md` defining how sync and flush should behave in the structured product. |
| Objective | Shift sync/flush from an operator-managed workflow into a system-managed workflow with only the right level of surfacing and intervention. |
| Output | A policy doc defining automatic sync/flush expectations, what gets surfaced on Scan vs Event screens, when manual flush is visible, when sync state becomes a warning vs background info, and what operators should not need to think about. |
| Note | Use the current architecture truth that auto-flush is normal and manual flush is fallback/debug. Ground the policy in `QueueViewModel`, `SyncViewModel`, `DiagnosticsViewModel`, and the semantic `SyncUiState` usage already on main. Do not propose primary UI patterns that make manual flush the center of the product. |

### What good output should conclude

- sync and flush are mostly automatic
- operators should mostly see status, not controls
- flush should not dominate the Scan screen
- queue and backlog health should be visible when they matter
- Event screen can expose more operational detail than Scan screen, but still not become a debug dump

---

## PR 8E — Runtime Adoption Strategy

### What this PR is

This PR decides how the repo should move from the current XML shell toward the structured product runtime.

### What it touches

Create:

- `android/scanner-app/docs/runtime_adoption_strategy.md`

### End goal for this PR

Choose the implementation path before code starts so later phases follow one clear runtime direction.

### Prompt

| Field | Content |
|---|---|
| Task | Create `android/scanner-app/docs/runtime_adoption_strategy.md` defining how the repo should move from the current XML shell to the structured product runtime. |
| Objective | Decide the implementation path before code starts: whether to keep the XML shell temporarily, whether to introduce an authenticated shell, and where Compose should enter first. |
| Output | A decision document comparing at least two grounded options and recommending one path with phased implementation order. |
| Note | The recommendation must be rooted in the current repo reality: XML/ViewBinding runtime today, Compose design-system foundation already merged, and a heavy `MainActivity`. Compare at least: (1) incremental XML/fragment restructuring first, and (2) staged authenticated-shell introduction that leverages the existing Compose design-system foundation while preserving repo/domain/backend boundaries. Recommend one path and justify it clearly. Smartphone-first scanner product is the priority. No code. |

### What good output should conclude

The recommendation should not be vague. It should explicitly choose one path and explain why.

A likely strong recommendation is:

- introduce the structured runtime shell deliberately
- do not keep investing in the current all-in-one XML shell as the long-term product
- stage adoption in controlled implementation phases after the planning set is complete

---

## Robust Tests / Evaluation / Regression Checks

Phase 8 is documentation-only, so there are no runtime tests to add yet.

But there **must** still be discipline checks to prevent planning churn and accidental code drift.

### Required validation for every PR in this phase

```bash
git diff --check
```

### Required scope checks for every PR in this phase

- Only the intended doc file for that PR is changed
- No Kotlin code changes
- No XML runtime changes
- No Gradle/build/tooling churn
- No design-system API changes
- No backend-contract assumptions added beyond current mobile endpoints

### Review checklist for every PR in this phase

- Is the document grounded in the current repo files?
- Does it explicitly preserve architecture truths?
- Does it avoid inventing unsupported backend features?
- Does it preserve smartphone-first priority?
- Does it keep hardware scanner support deferred?
- Does it keep manual flush secondary?
- Does it avoid sneaking implementation into planning?

---

## Recommended PR Order

1. PR 8A — Runtime architecture definition
2. PR 8B — Domain and data capability audit
3. PR 8C — Scanner interaction and battery policy
4. PR 8D — Sync/flush operator policy
5. PR 8E — Runtime adoption strategy

Only after those are complete should implementation planning for Phase 9 begin.

---

## What to Reject During Phase 8

Reject or push back if the output:

- tries to keep the current one-screen control panel as the long-term product
- invents backend APIs beyond login / attendees / scans
- makes manual flush a primary CTA
- keeps diagnostics as a first-class operator workflow
- designs smartphone and hardware-scanner UX as equal first priorities
- ignores attendee-model/data gaps for Search/Event ambitions
- starts implementing before runtime architecture is defined
- drifts back into design-system-only expansion

---

## What Success Looks Like for the Whole Phase

At the end of Phase 8, you should have:

- a real runtime architecture plan
- a grounded data capability audit
- a smartphone-first scanner and battery policy
- a clear sync/flush operator policy
- an explicit runtime adoption strategy
- no accidental code churn
- no fake rollout
- no product ambiguity about where the app is going next

That is the correct handoff point for the first runtime implementation phase.
