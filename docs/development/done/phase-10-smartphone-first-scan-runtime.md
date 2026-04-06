# Phase 10 — Smartphone-First Scan Runtime

## Phase / Plan Description

Phase 10 delivers the first real production operator workflow of the structured FastCheck scanner product: **login and start scanning with minimal friction, clear status, and sane smartphone battery behavior**.

This phase comes **after Phase 9** has established the session gate and authenticated shell. Phase 10 must not broaden into Search/Event implementation, diagnostics redesign, or hardware-scanner parity. It should focus on the **Scan** destination only.

The plan is rooted in the current repo state:

- Android runtime contract remains limited to:
  - `POST /api/v1/mobile/login`
  - `GET /api/v1/mobile/attendees`
  - `POST /api/v1/mobile/scans`
- Scanner analysis must never call network directly.
- Android is local-first, backend-authoritative.
- Auto-flush is the normal path; manual flush is fallback/debug.
- Current scanner capture already flows through `ScanCapturePipeline` into local queueing.
- Current `MainActivity` still owns scanner source binding, permission handling, and autoflush trigger orchestration.
- Smartphone camera scanning is the MVP priority; hardware-scanner UX expansion is deferred.

This phase should transform scanning from a temporary shell subsection into a **first-class operator screen**.

---

## What the Phase Touches

### Primary runtime areas
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/scanning/*`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/app/*`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/app/navigation/*` (from Phase 9 shell)
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/app/session/*` (from Phase 9 session gate)

### Existing repo areas that Phase 10 is expected to integrate with
- `feature/scanning/ui/ScanningViewModel.kt`
- `feature/scanning/ui/ScanningUiState.kt`
- `feature/scanning/usecase/ScanCapturePipeline.kt`
- `feature/scanning/usecase/ScannerSourceBinding.kt`
- `feature/queue/QueueViewModel.kt`
- `feature/queue/QueueUiState.kt`
- `core/designsystem/semantic/ScanUiState.kt`
- `core/designsystem/semantic/SyncUiState.kt`
- `core/designsystem/components/FcStatusChip.kt`
- `core/designsystem/components/FcBanner.kt`
- `core/designsystem/components/FcCard.kt`

### Likely new areas
- `feature/scanning/screen/*`
- possibly a small `feature/scanning/policy/*` or similar package for smartphone camera activation policy if a pure policy object is needed

### Areas this phase should **not** broaden into
- `feature/attendees/*` full Search/manual check-in implementation
- `feature/event/*` Event stats/ops implementation
- deep diagnostics redesign
- backend contract expansion
- hardware scanner productization

---

## What Success Looks Like — End Goal For Phase 10

By the end of Phase 10:

1. After login, the operator lands on a **dedicated Scan screen** inside the authenticated shell.
2. The Scan screen is clearly optimized for **smartphone camera scanning first**.
3. The operator can:
   - understand scanner readiness immediately
   - start/arm scanning clearly
   - receive immediate truthful scan feedback
   - understand queue/offline/backlog state without opening debug tools
4. The camera is **not treated as always-on by default** if that would waste battery.
5. Camera/session lifecycle is deliberate:
   - no active camera on non-Scan tabs
   - no active camera in background
   - predictable behavior when the user leaves and returns
6. Sync/flush remains mostly automatic; manual flush, if visible, is secondary.
7. The screen does **not** expose backend/admin details like API target, base URL, or deep diagnostics.
8. The implementation preserves current architecture truths:
   - scanner analysis still only hands off to local queueing
   - UI/ViewModels remain projection-only
   - backend admission truth is not faked in UI
9. The phase leaves Search and Event screens for later phases.

A good Phase 10 result should feel like the app has become a **real scanner product**, not just a styled control panel.

---

## Constraints

### Non-negotiable architecture constraints
- Do **not** change repository / worker / Room / backend contract behavior unless explicitly required and separately approved.
- Do **not** let scanner analysis call network code directly.
- Do **not** represent local queue acceptance as server-confirmed success.
- Keep UI/ViewModels projection-only over repository / Room / coordinator truth.
- Keep the current mobile API contract limited to login / attendees / scans.
- Manual flush must remain fallback/debug rather than primary operator workflow.

### Product constraints
- Smartphone camera scanning is the MVP priority.
- Hardware scanner / DataWedge / wedge flows are **future work**, not equal first-class design targets in this phase.
- Search/manual check-in is Phase 11.
- Event operations/stats is Phase 12.
- Overflow/support is Phase 13.

### UX constraints
- Do not make sync/flush the center of the screen.
- Do not expose API base URL, API target, token expiry, or other support/debug details on the Scan screen.
- Do not make the camera run 24/7 by default if it causes avoidable drain.
- Keep the Scan destination fast, obvious, and low-cognitive-load.

### Implementation constraints
- Do not add more design-system components in this phase.
- Use the existing design-system foundation already merged on `main`.
- Avoid overengineering scanner session state if a small pure policy layer is enough.
- Keep branch/PR slices small and independently reviewable.

---

## Worktree Creation

Use one worktree / one branch / one PR per subphase.

### Suggested worktree roots
```bash
mkdir -p ../fastcheck-worktrees
```

### PR 10A worktree
```bash
git fetch origin
git worktree add ../fastcheck-worktrees/phase10a-scan-destination origin/main -b codex/phase10-scan-destination
```

### PR 10B worktree
```bash
git fetch origin
git worktree add ../fastcheck-worktrees/phase10b-camera-policy origin/main -b codex/phase10-camera-session-policy
```

### PR 10C worktree
```bash
git fetch origin
git worktree add ../fastcheck-worktrees/phase10c-queue-health origin/main -b codex/phase10-queue-health-and-feedback
```

If PR 10B depends on pure policy/state additions from 10A, create it from the updated branch tip after 10A merges or rebase it cleanly before review.

---

## Detailed Prompts / Tasks / Plans

# PR 10A — Scan destination scaffold and operator-first runtime surface

### Branch
`codex/phase10-scan-destination`

### PR title
`[codex] phase 10 scan destination`

### Phase description
Create the first dedicated Scan destination inside the authenticated shell so scanning is no longer just one subsection of the old XML control panel.

### What this PR touches
- authenticated shell destination wiring from Phase 9
- new `feature/scanning/screen/*` files
- integration with existing `ScanningViewModel`, `QueueViewModel`, semantic scan/sync state, and design-system components
- minimal host-shell/runtime wiring needed to make Scan the real primary destination

### What success looks like
- `Scan` exists as a proper destination in the authenticated shell
- it surfaces scanner readiness, capture feedback, queue health, and concise operator messaging
- it uses current semantic/design-system foundation instead of raw ad hoc strings everywhere
- it does not yet solve final battery policy in full detail if that is split into PR 10B
- it does not broaden into Search/Event implementation

### Constraints
- no backend contract changes
- no attendee-search implementation
- no diagnostics redesign
- no hardware scanner UX expansion
- no broad camera-lifecycle rewrite unless necessary for safe host integration

### Detailed prompt
| Field | Content |
|---|---|
| Task | Implement the first production Scan destination for the authenticated FastCheck Android shell using the existing scanner, queue, sync, and semantic-state foundations. |
| Objective | Turn scanning into the clear primary operator workflow after login, without broadening into Search/Event or changing core repo/backend behavior. |
| Output | New `feature/scanning/screen/*` files and the minimum shell/runtime changes needed to make the Scan destination real and operator-facing. |
| Note | Root the work in the existing repo: `ScanningViewModel`, `ScanningUiState`, `ScanCapturePipeline`, `QueueViewModel`, semantic `ScanUiState` / `SyncUiState`, and the merged design-system foundation. Keep the screen smartphone-first and operator-focused. Surface scanner readiness, capture feedback, queue depth, and concise upload health. Keep diagnostics/admin details off the Scan screen. Do not widen into Search/Event implementation. Do not let scanner analysis call network code. Preserve truthful semantics: queued locally is not uploaded/accepted. |

### Robust tests
- add or extend unit tests for any new pure mapper/presenter logic used to project `ScanningUiState` + queue/sync state into Scan screen models
- test truthful presentation of scan states if a new presenter/mapping layer is added
- test that queued/local states remain distinct from uploaded/server-confirmed states
- avoid screenshot tests unless the repo already has a stable pattern for them
- keep UI tests narrow if added at all; prefer pure decision-logic tests

### Validation
```bash
git diff --check
JAVA_HOME=/home/jcschoeman96/.jdks/jdk-25.0.2+10 bash ./gradlew -Dorg.gradle.java.home=/home/jcschoeman96/.jdks/jdk-25.0.2+10 :app:compileDebugKotlin :app:testDebugUnitTest
```

---

# PR 10B — Smartphone camera session and battery policy

### Branch
`codex/phase10-camera-session-policy`

### PR title
`[codex] phase 10 camera session policy`

### Phase description
Implement the smartphone-first camera/session behavior so the Scan destination is battery-aware and predictable instead of implicitly always-on.

### What this PR touches
- scanner-session activation policy and/or shell-level lifecycle rules
- `ScanningViewModel` and/or a new small pure scanner policy model if needed
- host-shell behavior for tab switching and background/foreground interaction
- camera preview visibility/arming behavior

### What success looks like
- camera is not left active by accident on non-Scan tabs
- camera is not left active in background
- scan session behavior is explicit: idle/armed/active or similar
- behavior is simple enough to maintain
- smartphone battery posture is materially better than “camera just runs whenever possible”

### Constraints
- smartphone-first only
- do not optimize equally for DataWedge/hardware yet
- preserve existing source abstraction without expanding it into a giant product matrix
- do not make scan flow slower or confusing in the field
- do not move queue/sync/domain logic into scanner lifecycle code

### Detailed prompt
| Field | Content |
|---|---|
| Task | Implement the smartphone-first camera/session policy for the production Scan destination, including active/idle behavior, tab-switch behavior, and background/foreground behavior. |
| Objective | Prevent the new Scan screen from inheriting naive always-on camera behavior and make smartphone scanning battery-aware without sacrificing operator speed. |
| Output | Small, maintainable runtime changes plus any pure policy/state files needed to drive camera activation and preview behavior on the Scan destination. |
| Note | Root this in the current repo: `ScanningViewModel`, `ScanningUiState`, `ScannerSourceBinding`, `MainActivity` scanner binding behavior, and the current source-type model. Smartphone camera scanning is the MVP priority. Hardware/DataWedge behavior is future work; do not co-design them as equal first-class UX paths in this phase. The camera should not remain active on non-Scan tabs or in background. Prefer a simple explicit session model such as idle/armed/active over clever hidden behavior. Keep the implementation grounded and testable. |

### Robust tests
- create pure unit tests for any new camera/session activation policy object
- test background/foreground decision logic if extracted into a pure evaluator
- test tab-selection or visibility policy if represented as pure logic
- test that camera-active conditions are stricter than “permission granted + app started” when smartphone-first policy requires it
- avoid instrumentation-heavy tests unless absolutely necessary

### Validation
```bash
git diff --check
JAVA_HOME=/home/jcschoeman96/.jdks/jdk-25.0.2+10 bash ./gradlew -Dorg.gradle.java.home=/home/jcschoeman96/.jdks/jdk-25.0.2+10 :app:compileDebugKotlin :app:testDebugUnitTest
```

---

# PR 10C — Queue health, operator feedback, and secondary recovery actions

### Branch
`codex/phase10-queue-health-and-feedback`

### PR title
`[codex] phase 10 queue health and feedback`

### Phase description
Refine the Scan destination so operators can understand scan outcomes and queue/upload health quickly, without turning the screen into a sync/debug dashboard.

### What this PR touches
- Scan destination UI presentation
- semantic feedback wiring from current scan/sync truth
- queue health / backlog / offline messaging
- secondary manual recovery actions if justified

### What success looks like
- scan success/failure/offline/duplicate feedback is clear and truthful
- queue depth and upload health are visible but not overwhelming
- manual flush is secondary and only where justified
- operator can stay focused on scanning
- no backend/admin clutter is reintroduced

### Constraints
- manual flush cannot become a primary CTA
- no full Event screen logic here
- no diagnostics dump here
- no new component sprawl
- do not pretend local queue acceptance equals server acceptance

### Detailed prompt
| Field | Content |
|---|---|
| Task | Refine the Scan destination’s operator messaging, queue health surfacing, and secondary recovery affordances using the existing semantic state foundation. |
| Objective | Ensure the operator can trust what happened after each scan and understand whether the system is healthy, offline, or backlogged without needing to think about infrastructure details. |
| Output | Focused Scan destination changes only: semantic feedback presentation, concise queue/upload health surfacing, and any justified secondary recovery action wiring. |
| Note | Use existing semantic truth already on `main`: `ScanUiState`, `SyncUiState`, `QueueViewModel`, `ScanningViewModel`, and the design-system components. Keep feedback concise, truthful, and operational. Queue depth and upload health may be surfaced, but manual flush must remain fallback/debug and should not become the main center action. Keep backend/environment details out of the screen. Do not broaden into Event/Search implementation. |

### Robust tests
- test any new presenter logic that maps queue/scanning/coordinator states into operator-facing banner/chip/card sections
- test offline/backlog/manual-recovery visibility rules if encoded as pure logic
- test duplicate/invalid/offline distinctions remain explicit
- test that fallback/recovery actions are not surfaced as primary under normal healthy conditions

### Validation
```bash
git diff --check
JAVA_HOME=/home/jcschoeman96/.jdks/jdk-25.0.2+10 bash ./gradlew -Dorg.gradle.java.home=/home/jcschoeman96/.jdks/jdk-25.0.2+10 :app:compileDebugKotlin :app:testDebugUnitTest
```

---

## Recommended PR Order

1. **PR 10A — Scan destination scaffold**
2. **PR 10B — Smartphone camera session policy**
3. **PR 10C — Queue health and operator feedback**

Why this order:
- 10A establishes the real production Scan destination
- 10B makes the smartphone camera behavior safe and deliberate
- 10C refines operator trust and recovery messaging once the screen shape exists

---

## Robust Test Strategy for the Whole Phase

### Tests that are worth adding
- pure state/presenter tests for Scan destination projection logic
- pure policy tests for camera activation / battery behavior
- semantic truth tests for scan and sync UI-state usage in the Scan destination
- guardrail tests ensuring local queue acceptance is not rendered as uploaded/server-confirmed success

### Tests to avoid unless there is a very strong reason
- broad screenshot suites
- fragile UI harness tests that try to prove every layout detail
- tests that duplicate current repo internals without protecting a meaningful decision boundary

### Regression goals
Future regressions should be stopped if they try to:
- leave camera active on non-Scan tabs
- leave camera active while backgrounded
- expose backend/admin details on the Scan screen
- promote manual flush to primary operator workflow
- blur queued-local vs uploaded/server-confirmed status
- reintroduce the old control-panel feel into the Scan destination

---

## Risks and Edge Cases to Address in Review

- operator lands on Scan before attendee sync freshness is ideal
- permission denied / revoked while using Scan tab
- app backgrounds while camera is armed/active
- queue backlog grows while operator keeps scanning
- duplicate / cooldown / local failure semantics get muddled
- manual flush visibility becomes too prominent
- smartphone-first battery rules accidentally break future source abstraction

---

## References in Current Repo

Use these repo files as the grounding set for this phase:

- `android/scanner-app/docs/architecture.md`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/app/MainActivity.kt`
- `android/scanner-app/app/src/main/res/layout/activity_main.xml`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/scanning/ui/ScanningViewModel.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/scanning/ui/ScanningUiState.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/scanning/usecase/ScanCapturePipeline.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/scanning/usecase/ScannerSourceBinding.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/queue/QueueViewModel.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/queue/QueueUiState.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/core/designsystem/semantic/ScanUiState.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/core/designsystem/semantic/SyncUiState.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/core/designsystem/components/FcStatusChip.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/core/designsystem/components/FcBanner.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/core/designsystem/components/FcCard.kt`

---

## End Goal Summary

Phase 10 is complete when the app has a **real smartphone-first Scan destination** that:

- is the primary post-login operator surface
- is battery-aware and lifecycle-safe
- provides clear truthful scan feedback
- treats sync/flush mostly as background system behavior
- exposes only the operator-relevant health signals needed to keep scanning confidently

This phase should feel like the scanner product finally starts behaving like a product.
