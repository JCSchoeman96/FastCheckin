# Phase 14 — Hardware Scanner Expansion Plan

## Phase / Plan Description

Phase 14 is a **planning and product-expansion phase**, not an implementation phase.

The purpose of this phase is to define how the FastCheck Android scanner app should expand from the **smartphone-first MVP** into a product that can later support dedicated scanner hardware cleanly, without compromising the smartphone UX that Phase 10 optimizes first.

This phase exists because the repo already has the beginnings of multi-source scanner support in the domain/runtime shape:

- `ScannerSourceType` already distinguishes `CAMERA`, `KEYBOARD_WEDGE`, and `BROADCAST_INTENT` sources.
- `CameraScannerInputSource` already exists for smartphone camera scanning.
- `DataWedgeScannerInputSource` already exists for broadcast-intent-based hardware/scanner integrations such as Zebra DataWedge.
- build config already allows scanner source selection through `FASTCHECK_SCANNER_SOURCE` with `camera` and `datawedge` values.

That means hardware expansion should be treated as a **deliberate product layer on top of a stable smartphone-first app**, not as a speculative future idea and not as something to prematurely optimize for during smartphone MVP work.

This phase must define:

1. which source modes the product will eventually support,
2. how smartphone and hardware scanner UX differ,
3. what shell/runtime behaviors must become source-aware,
4. what code seams are already sufficient,
5. what must remain deferred until the smartphone-first runtime is proven correct.

This phase must **not** ship real hardware-scanner runtime behavior changes yet.

---

## Repo Grounding

This phase is rooted in the current repo state:

- `architecture.md` still defines the Android runtime contract as only `login`, `attendees`, and `scans`, and requires UI/ViewModels to remain projection-only over repository/Room/coordinator truth.
- `CameraScannerInputSource` is already a camera-backed `ScannerInputSource` that binds CameraX + ML Kit and emits source-level capture events only.
- `DataWedgeScannerInputSource` is already a broadcast-intent-backed `ScannerInputSource` that registers/unregisters a receiver and emits capture events only.
- `ScannerSourceType` is already intentionally small and concrete.
- `MainActivity` currently resolves a scanner source mode and activates the source through `ScannerSourceBinding`.
- build config already allows `FASTCHECK_SCANNER_SOURCE=camera|datawedge`.

This phase therefore plans from **real code and existing seams**, not from imagined abstractions.

---

## What the Phase Touches

This phase is planning-only and should touch documentation only.

### Expected touched areas

- `android/scanner-app/docs/`

### Recommended new docs

1. `android/scanner-app/docs/hardware_scanner_expansion_plan.md`
2. `android/scanner-app/docs/scanner_source_product_rules.md`
3. `android/scanner-app/docs/scanner_source_runtime_matrix.md`

If you want to keep this phase tighter, PR 14A can create the main plan doc first and PR 14B/14C can add the more detailed support docs.

### This phase must not touch

- runtime feature code under `app/src/main/java/`
- `MainActivity.kt`
- scanner source implementations
- queue/domain/repository behavior
- XML runtime screens
- Compose runtime screens
- network contract code
- Room schema or repositories

---

## What Success Looks Like — End Goal for the Phase

Phase 14 is successful when the repo contains a **clear, implementation-grounded plan** for future hardware scanner support that:

1. keeps smartphone camera scanning as the first-class MVP and baseline,
2. defines how hardware scanner behavior differs by source type,
3. identifies what shell/runtime behaviors must eventually become source-aware,
4. avoids contaminating the smartphone-first UX with premature hardware compromises,
5. makes later implementation work explicit and low-ambiguity.

By the end of Phase 14, the team should be able to answer:

- What exactly changes when the app runs on smartphone camera vs DataWedge/hardware scanner?
- Which product behaviors stay identical across all sources?
- Which operator-facing behaviors should differ by source type?
- What lifecycle, battery, and activation policies must be source-aware?
- What should remain deferred until after the smartphone-first runtime is stable?
- What is the implementation order for the future hardware-scanner rollout?

Phase 14 is **not** successful if it only says “support hardware scanners later.”
It must define the actual product/runtime differences and the repo seams that will carry them.

---

## Constraints

### Product constraints

- Smartphone camera scanning remains the MVP and current first priority.
- Hardware scanner UX must not distort the smartphone operator experience.
- Hardware scanner support is a future product expansion, not a present equal-priority runtime target.

### Architecture constraints

- Respect `android/scanner-app/docs/architecture.md`.
- Preserve the current mobile runtime contract: `login`, `attendees`, `scans` only.
- Preserve scanner truth: scanner sources emit captures into queueing only; they do not directly call network code.
- Preserve UI truth: local queue acceptance is not server-confirmed admission.
- Preserve queue/flush truth: auto-flush remains normal; manual flush remains fallback/debug.

### Implementation constraints

- No runtime code changes in this phase.
- No changes to `MainActivity`, scanner input sources, or shell/navigation code in this phase.
- No backend contract expansion in this phase.
- No new scanner-source implementation in this phase.
- No screen rollout or UI redesign in this phase.

---

## Worktree Creation

Use one worktree/branch per PR.

### Recommended worktrees / branches

#### PR 14A
- Worktree: `../FastCheckin-phase14-source-plan`
- Branch: `codex/phase14-source-plan`
- PR title: `[codex] phase 14 hardware scanner expansion plan`

#### PR 14B
- Worktree: `../FastCheckin-phase14-product-rules`
- Branch: `codex/phase14-source-product-rules`
- PR title: `[codex] phase 14 scanner source product rules`

#### PR 14C
- Worktree: `../FastCheckin-phase14-runtime-matrix`
- Branch: `codex/phase14-source-runtime-matrix`
- PR title: `[codex] phase 14 scanner source runtime matrix`

---

## Detailed Prompts / Tasks / Plans

# PR 14A — Main Hardware Scanner Expansion Plan

## What this PR is

This PR creates the primary planning document for expanding from smartphone-first scanning to future hardware-scanner support.

## What it touches

- `android/scanner-app/docs/hardware_scanner_expansion_plan.md`

## Success for PR 14A

A clear planning doc that:

- explains why smartphone-first remains the baseline,
- inventories current scanner-source seams already present in the repo,
- defines the intended future source modes,
- records what is shared vs source-specific,
- sets the implementation order for future hardware support.

## Prompt 14A

| Field | Content |
|---|---|
| Task | Create `android/scanner-app/docs/hardware_scanner_expansion_plan.md` describing how the FastCheck Android app should evolve from the current smartphone-first scanning runtime to future hardware-scanner support. |
| Objective | Turn the repo’s existing scanner-source abstraction into a concrete future product plan without changing current smartphone-first runtime behavior. |
| Output | One grounded planning doc covering current source seams, future source modes, shared behaviors, source-specific behaviors, deferred decisions, and future implementation order. |
| Note | Root this doc in the current repo: `architecture.md`, `ScannerSourceType`, `CameraScannerInputSource`, `DataWedgeScannerInputSource`, `ScannerSourceBinding`, `MainActivity`, and build config scanner-source selection. Smartphone camera scanning remains MVP priority. Do not write implementation code. Do not propose making hardware-scanner UX an equal first-class target now. Keep the doc grounded in the current mobile contract and queue/admission rules. |

## Required content for PR 14A

The doc should include:

1. **Current scanner-source seams already present**
   - source type enum
   - camera source implementation
   - DataWedge/broadcast source implementation
   - shell activation and source binding
   - build-time source selection

2. **Future supported source modes**
   - smartphone camera scanning
   - DataWedge/broadcast-intent scanner path
   - possible keyboard wedge path later if still relevant

3. **Shared behaviors across all source types**
   - capture -> local queue handoff only
   - same backend admission path
   - same queue/flush semantics
   - same semantic scan feedback truth

4. **Source-specific product behavior differences**
   - camera lifecycle and battery behavior
   - scan-session activation differences
   - permission differences
   - foreground/background expectations
   - UI affordance differences

5. **Future implementation order**
   - smartphone MVP remains baseline
   - hardware productization only after smartphone runtime proves stable

---

# PR 14B — Scanner Source Product Rules

## What this PR is

This PR defines the operator-facing product rules for different scanner source types.

## What it touches

- `android/scanner-app/docs/scanner_source_product_rules.md`

## Success for PR 14B

A policy doc that makes source-type behavior explicit enough that future implementation work will not guess.

## Prompt 14B

| Field | Content |
|---|---|
| Task | Create `android/scanner-app/docs/scanner_source_product_rules.md` defining operator-facing product rules for smartphone camera scanning vs future hardware scanner modes. |
| Objective | Ensure future source-aware runtime work is product-led, not adapter-led, and prevent hardware support from warping the smartphone-first UX. |
| Output | A policy doc covering source-specific UX, activation models, permission handling, battery expectations, tab/shell behavior, and fallback/support behavior. |
| Note | Root this in the current scanner source abstraction and smartphone-first product goals. Make explicit that camera mode and DataWedge mode must not be treated as identical UX just because both implement `ScannerInputSource`. No code. No runtime changes. |

## Required content for PR 14B

The doc should define:

### Smartphone camera product rules
- camera scanning is explicit and battery-aware
- camera should only be active when appropriate for the Scan screen/session
- permission UX matters and must remain user-visible
- tab switching/backgrounding should stop or pause camera activity

### DataWedge / hardware product rules
- no camera permission path
- scanner may be considered “always ready” differently than camera mode
- hardware-trigger-friendly workflow may differ from smartphone touch-driven workflow
- battery behavior expectations differ from camera mode

### Cross-source rules
- source type must not change business truth
- source type must not bypass queue/admission behavior
- source type must not create a second token/session system
- source type must not create inconsistent operator semantics for outcomes like duplicate/offline/queued/uploaded

### Future support rules
- settings/debug may expose source information later, but source selection should not pollute the operator’s main workflow
- hardware-support surfaces should remain support/admin scoped unless a future product decision changes that deliberately

---

# PR 14C — Scanner Source Runtime Matrix

## What this PR is

This PR creates the concrete matrix that maps source type to lifecycle, shell, permissions, battery, and support implications.

## What it touches

- `android/scanner-app/docs/scanner_source_runtime_matrix.md`

## Success for PR 14C

A concise matrix that future implementation phases can use to avoid ambiguity.

## Prompt 14C

| Field | Content |
|---|---|
| Task | Create `android/scanner-app/docs/scanner_source_runtime_matrix.md` mapping each scanner source type to runtime behavior expectations. |
| Objective | Give future implementation phases a low-ambiguity reference for how camera, broadcast-intent/DataWedge, and possible keyboard-wedge sources should differ in runtime behavior. |
| Output | A matrix document with rows for scanner source types and columns for lifecycle, permissions, activation model, battery behavior, shell implications, support implications, and implementation priority. |
| Note | Use the current repo source types as the baseline. Keep smartphone camera as Priority 1 and hardware scanner support as later expansion. Keep the matrix implementation-grounded and compact. No code. |

## Recommended runtime matrix columns

- Source type
- Current repo support state
- MVP priority level
- Permission requirements
- Activation model
- Foreground/background behavior
- Battery considerations
- Operator-facing UI differences
- Overflow/support implications
- Future implementation phase

### Expected rows

- `CAMERA`
- `BROADCAST_INTENT`
- `KEYBOARD_WEDGE` (future/deferred if still relevant)

---

## Suggested Phase 14 Conclusions

A strong Phase 14 should conclude:

- smartphone camera mode remains the reference UX,
- DataWedge/hardware support should align to the same admission/queue truth,
- source-type differences should primarily affect shell behavior, scanner activation, permissions, battery policy, and operator affordances,
- future hardware support should be layered on top of the structured runtime already created in earlier phases,
- support/admin surfaces may later expose source diagnostics, but source complexity must not bleed into the main operator path.

---

## Robust Tests / Evaluation / Regression Guardrails

This phase is planning-only, so it should not add runtime tests.

### Required evaluation for this phase

- `git diff --check`
- confirm docs-only scope
- confirm no code or build-file churn
- confirm no accidental runtime implementation work sneaks into the PRs

### What future regressions this phase is meant to prevent

This phase is designed to prevent later implementation regressions such as:

- treating camera and hardware-scanner UX as identical,
- distorting the smartphone-first scan experience for hypothetical hardware support,
- bypassing queue/admission truth for hardware scanner flows,
- exposing source-type complexity directly to operators too early,
- coupling source-type support to backend/session redesign,
- building hardware-specific UI flows before the smartphone runtime is stable.

### What to reject in Codex output

Reject or push back if Codex:

- starts implementing runtime scanner-source changes,
- changes `MainActivity`, scanner input sources, or queue/admission code,
- proposes equal first-priority support for smartphone and hardware scanner UX,
- invents backend APIs or session/auth flows for hardware devices,
- turns the docs into vague prose instead of repo-grounded decisions,
- proposes source-aware product behavior that conflicts with current queue/admission truth.

---

## Recommended Execution Order

1. PR 14A — main expansion plan
2. PR 14B — source product rules
3. PR 14C — runtime matrix

That order keeps the phase deterministic:
- first define the strategic plan,
- then define product behavior rules,
- then lock them into a compact runtime matrix for future implementation.

---

## Final End Goal for Phase 14

By the end of Phase 14, the repo should have a clear answer to this question:

**How does FastCheck later expand from a smartphone-first scanner product into a hardware-scanner-capable product without breaking the current architecture, operator truth model, or smartphone UX?**

That answer must be written down before future hardware support work starts.
