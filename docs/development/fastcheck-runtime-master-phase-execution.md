# FastCheck Android Runtime — Master Phase Execution Guide

This document is the **top-level execution control file** for the Android structured-runtime track.

Use it to keep phase work disciplined, prevent scope creep, and make sure each phase only implements what it owns.

This file does **not** replace the individual phase breakdown docs.  
It tells the coding agent:

1. what the overall runtime direction is,
2. what is already decided,
3. what each phase owns,
4. what is explicitly deferred,
5. which supporting docs must be referenced for the current phase,
6. and what must be checked on `main` before starting implementation.

---

## 1. How to use this document

For every new runtime phase:

1. Read this master execution guide first.
2. Verify which prior phase PRs are **actually merged on `main`**.
3. Then read the **current phase breakdown doc**.
4. Then read only the **minimum upstream supporting docs** listed for that phase.
5. Do **not** pull work forward from later phases.
6. Do **not** assume stacked or previously implemented PRs are already landed unless verified on `main`.

This guide exists because implementation work can drift if the agent only sees one phase in isolation.

---

## 2. Global runtime direction

The Android scanner app is being reshaped from a temporary all-in-one XML/ViewBinding control panel into a structured scanner product.

The intended product shape is:

- **Unauthenticated login gate**
- **Authenticated shell**
  - `Scan`
  - `Search`
  - `Event`
- **Overflow / support**
  - permissions recovery
  - diagnostics
  - preferences only if justified
  - logout

The product priority order is fixed:

1. login and start scanning
2. attendee search / manual check-in / attendee details
3. event operational visibility
4. support/admin utilities in overflow

---

## 3. Runtime truths that every phase must preserve

These are non-negotiable unless there is an explicit contract/architecture decision changing them.

### Android runtime contract
Android currently depends only on:

- `POST /api/v1/mobile/login`
- `GET /api/v1/mobile/attendees`
- `POST /api/v1/mobile/scans`

No phase may silently invent or assume additional mobile runtime APIs.

### Architecture truth
- Android is local-first.
- Phoenix/backend remains authoritative for admission/auth/sync truth.
- Scanner analysis must never call network code directly.
- UI/ViewModels remain projection-only over repository / Room / coordinator truth.
- Local queue acceptance must never be presented as server-confirmed admission.
- Auto-flush is the normal path.
- Manual flush remains fallback/debug unless explicitly re-approved later.

### Product truth
- Smartphone camera scanning is the MVP and first priority.
- Hardware scanner / DataWedge productization is explicitly deferred until later.
- Diagnostics must not become a primary operator workflow.
- Backend/environment details must not be promoted into the main operator path.

### Design-system truth
- Use the existing merged design-system foundation.
- Do not add new components casually.
- Do not add `FcBadge` unless a later phase explicitly re-opens that decision.
- Do not create parallel semantic systems.

---

## 4. Phase ownership map

## Phase 8 — Runtime Architecture and Workflow Definition
**Type:** planning only

**Owns:**
- runtime architecture
- data capability audit
- scanner interaction policy
- sync/flush operator policy
- runtime adoption strategy

**Does not own:**
- runtime implementation
- shell code
- Scan/Search/Event implementation
- backend or Android contract changes

**Definition of done:**
- repo has implementation-ready planning docs
- runtime direction is explicit
- adoption sequence is explicit

---

## Phase 9 — Session Gate and Authenticated Shell Scaffold
**Type:** implementation

**Owns:**
- session gate
- authenticated shell
- shell route split
- bottom-nav information architecture
- overflow scaffold
- temporary legacy runtime bridge behind `Scan`

**Does not own:**
- final Scan runtime
- final Search workflow
- final Event operations screen
- support/diagnostics redesign

**Definition of done:**
- login is a real gate
- authenticated shell exists
- `Scan / Search / Event` exist as product destinations
- current working operator runtime is still reachable through the temporary `Scan` bridge
- `MainActivity` is less monolithic than before

---

## Phase 10 — Smartphone-First Scan Runtime
**Type:** implementation

**Owns:**
- first real production Scan destination
- smartphone-first camera/session behavior
- battery-aware scanner lifecycle rules
- concise queue/upload health surfacing on Scan
- truthful operator scan feedback

**Does not own:**
- Search/manual check-in
- Event operations screen
- diagnostics/overflow redesign
- hardware scanner parity

**Definition of done:**
- Scan becomes a real operator screen
- smartphone camera behavior is controlled and sane
- queue/upload health is visible but secondary
- screen no longer feels like a control-panel subsection

---

## Phase 11 — Attendee Search and Manual Check-In Foundation
**Type:** implementation

**Owns:**
- attendee projection/model cleanup for Search
- local attendee query/search foundation
- Search destination
- attendee details
- manual check-in/manual scan action via existing queue/admission path

**Does not own:**
- backend search APIs
- separate manual-check-in network APIs
- Event ops screen
- diagnostics/support overflow work

**Definition of done:**
- Search is a real local-first feature
- attendee details are useful and truthful
- manual intervention works through existing queue semantics
- queued-local truth is not blurred with server-confirmed truth

---

## Phase 12 — Event Operations Screen
**Type:** implementation

**Owns:**
- Event destination
- event-ops projection layer
- curated event health UI
- supportable event metrics from current local/session/coordinator truth
- only secondary controls if clearly justified

**Does not own:**
- diagnostics dump resurrection
- backend health API expansion
- search/manual check-in
- overflow/support surfaces

**Definition of done:**
- Event tab is a calm operational overview
- key session/sync/queue/flush health is visible
- only truthful supportable metrics are shown
- debug/admin details remain out of the main operator path

---

## Phase 13 — Overflow and Support Surfaces
**Type:** implementation

**Owns:**
- overflow entry point
- support/admin destination scaffold
- logout
- permissions troubleshooting
- controlled diagnostics access
- preferences only if justified

**Does not own:**
- main Scan/Search/Event product logic
- backend/environment controls for operators
- hardware-scanner product work

**Definition of done:**
- support/admin actions are available but secondary
- logout is straightforward
- diagnostics are accessible without dominating the product
- support surfaces feel deliberate, not like a debug console

---

## Phase 14 — Hardware Scanner Expansion Plan
**Type:** planning only

**Owns:**
- future source-mode product plan
- hardware scanner product rules
- source runtime matrix

**Does not own:**
- hardware runtime implementation
- source-specific shell changes
- backend/session redesign

**Definition of done:**
- repo has a clear plan for later hardware expansion
- smartphone-first runtime remains the baseline
- future source-aware behavior is documented before implementation starts

---

## 5. Approved execution order

The sequence is fixed unless deliberately re-planned:

1. Phase 8 — planning
2. Phase 9 — session gate + shell scaffold
3. Phase 10 — Scan runtime
4. Phase 11 — Search/manual check-in
5. Phase 12 — Event operations
6. Phase 13 — Overflow/support
7. Phase 14 — later hardware expansion planning

Do not reorder these casually.

---

## 6. Phase reference matrix

This tells the agent what to read for each phase.

## For Phase 9
Read:
- this master guide
- Phase 9 breakdown doc
- all Phase 8 planning docs

Why:
Phase 9 is the first implementation phase after the planning set.

## For Phase 10
Read:
- this master guide
- Phase 10 breakdown doc
- `runtime_architecture.md`
- `scanner_interaction_policy.md`
- `operator_sync_flush_policy.md`
- `runtime_adoption_strategy.md`

Usually do **not** pull in the full data capability audit unless the Scan implementation actually depends on a Search/Event data truth question.

## For Phase 11
Read:
- this master guide
- Phase 11 breakdown doc
- `runtime_architecture.md`
- `runtime_data_capability_audit.md`
- `runtime_adoption_strategy.md`

Optionally include the merged Phase 10 summary or relevant files if Search integration depends on shell/runtime behavior established there.

## For Phase 12
Read:
- this master guide
- Phase 12 breakdown doc
- `runtime_architecture.md`
- `runtime_data_capability_audit.md`
- `operator_sync_flush_policy.md`
- `runtime_adoption_strategy.md`

## For Phase 13
Read:
- this master guide
- Phase 13 breakdown doc
- `runtime_architecture.md`
- `operator_sync_flush_policy.md`

Optionally include the Event doc if support/admin relocation must respect the final Event ownership boundaries.

## For Phase 14
Read:
- this master guide
- Phase 14 breakdown doc
- `scanner_interaction_policy.md`
- `runtime_adoption_strategy.md`

Optionally include Phase 10 output if hardware planning must explicitly build from the smartphone-first runtime baseline.

---

## 7. Current-state verification rule

Before implementing any phase, the coding agent must verify:

1. which related prior PRs are merged on `main`
2. whether the current phase baseline actually exists on `main`
3. whether stacked/unmerged work is being mistaken for landed work

This is mandatory.

Do not assume:
- “implemented on a branch” == “landed”
- “previously reviewed” == “merged”
- “phase doc exists” == “phase implementation exists”

If prior work is closed/unmerged or only on a branch, that must be said explicitly before continuing.

---

## 8. Scope-creep rules by phase

### When working on Phase 9
Do not:
- finish the real Scan screen
- start Search/Event feature implementation
- redesign diagnostics
- add hardware-scanner UX work

### When working on Phase 10
Do not:
- turn Search/Event into side quests
- expose backend/admin clutter on Scan
- promote manual flush to a primary CTA
- optimize equally for hardware scanners

### When working on Phase 11
Do not:
- invent backend search/manual-check-in APIs
- blur queued-local and server-confirmed truth
- broaden into Event stats
- move diagnostics into Search

### When working on Phase 12
Do not:
- re-skin diagnostics as Event
- fake metrics the app cannot support truthfully
- make sync/flush the center of the Event screen

### When working on Phase 13
Do not:
- elevate diagnostics into primary navigation
- create a giant settings framework
- expose backend environment controls to normal operators

### When working on Phase 14
Do not:
- implement runtime hardware support yet
- make hardware UX equal-priority with smartphone MVP
- redesign auth/session/backend contracts around hardware prematurely

---

## 9. Validation discipline

Every phase must still use narrow, honest validation.

### Minimum
- `git diff --check`

### Android implementation phases
- run the project’s standard Android compile/test validation for the touched slice

### Docs/planning phases
- keep changes docs-only
- verify only the intended doc files changed
- no accidental Kotlin/XML/Gradle/backend churn

### Repo-wide claims
Do not claim a phase is complete unless:
- the PRs are actually open/merged as appropriate
- validation was actually run
- the repo state matches the claim

---

## 10. Canonical instruction block for Codex

Use this at the top of future Codex prompts:

> Read the FastCheck Android Runtime Master Phase Execution Guide first.  
> Then verify which related prior phase PRs are actually merged on `main`.  
> Then read the current phase breakdown doc and only the supporting docs listed for that phase.  
> Implement only the current phase scope.  
> Do not pull work forward from later phases.  
> If the repo state does not match the expected baseline for the current phase, say so explicitly before making changes.

---

## 11. Practical rule for you

When briefing Codex for a phase, give it:

1. this master execution guide
2. the current phase breakdown doc
3. only the upstream docs that directly constrain that phase
4. any merged implementation PR summary or repo file set that now represents the actual baseline

Do **not** dump every phase doc every time.

---

## 12. Final rule

This runtime track succeeds only if each phase stays honest about:

- what is already on `main`
- what the current phase owns
- what is explicitly deferred
- what must remain true about backend authority, local-first runtime, and smartphone-first product direction

If a phase starts solving problems owned by later phases, stop and narrow it again.
