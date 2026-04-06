# Phase 13 — Overflow and Support Surfaces

## Phase / Plan Description

Phase 13 defines and then implements the **low-frequency support/admin surfaces** for the structured FastCheck Android scanner product.

This phase exists to move non-primary actions and information **out of the operator’s main path** and into a controlled overflow/support area.

The product direction is already clear:
- operators should primarily **log in and scan**
- search/manual check-in is secondary
- event operations is tertiary
- diagnostics, preferences, permissions troubleshooting, and logout must remain available but **must not dominate the app shell**

This phase is rooted in the current repo reality:
- the existing runtime still surfaces diagnostics and support details directly in the old main shell, including auth state, token expiry, API target, base URL, queue depth, flush summaries, and a manual diagnostics refresh path
- `SessionRepository` already supports `logout()`
- permission and scanner recovery currently live inside `MainActivity` and `ScanningViewModel`
- UI/runtime boundaries remain projection-only and the backend contract remains narrow

This phase should **not** become a broad settings system or a second diagnostics dashboard. It should establish a clean overflow/support experience that is discoverable, secondary, and safe.

---

## Repo Grounding

### Current relevant repo truths

The Android runtime contract is still intentionally narrow:
- `POST /api/v1/mobile/login`
- `GET /api/v1/mobile/attendees`
- `POST /api/v1/mobile/scans`

Auto-flush remains the normal upload path and manual flush remains fallback/debug. UI/ViewModels remain projection-only over repository/Room/coordinator truth. Scanner analysis must never call network directly. See `android/scanner-app/docs/architecture.md` for the active runtime boundaries.
The current support/admin truth is already represented in the app, but it is incorrectly elevated in the runtime shell:
- `MainActivity` coordinates auth, sync, diagnostics refresh, scanner permission, scanner source binding, queue/flush, and scanning state
- `activity_main.xml` exposes diagnostics and support-style information directly in the same shell as login and scanning
- `DiagnosticsUiState` currently includes `currentEvent`, `authSessionState`, `tokenExpiryState`, `apiTargetLabel`, `apiBaseUrl`, `lastAttendeeSyncTime`, `attendeeCount`, `localQueueDepthLabel`, `uploadStateLabel`, `serverResultSummary`, and `latestFlushSummary`
- `SessionRepository` already has a `logout()` boundary
- `SessionProvider` already exposes token presence for diagnostics/projection use, but UI should continue to depend on session/domain boundaries rather than token behavior directly

### Relevant current files

- `android/scanner-app/docs/architecture.md`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/app/MainActivity.kt`
- `android/scanner-app/app/src/main/res/layout/activity_main.xml`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/diagnostics/DiagnosticsViewModel.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/diagnostics/DiagnosticsUiState.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/diagnostics/DiagnosticsUiStateFactory.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/scanning/ui/ScanningViewModel.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/scanning/ui/ScanningUiState.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/data/repository/SessionRepository.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/core/network/SessionProvider.kt`

---

## What the Phase Touches

### Primary app areas
- authenticated app shell overflow entry point
- support/admin destination(s)
- logout flow
- permissions troubleshooting / scanner recovery surface
- controlled diagnostics access
- optional lightweight preferences scaffold, only if justified

### New package areas likely needed
- `app/navigation/` overflow menu wiring if not already introduced earlier
- `feature/settings/` or `feature/support/` for overflow-owned screens
- controlled reuse of `feature/diagnostics/*`

### Existing areas this phase may integrate with
- `feature.diagnostics.*`
- `feature.scanning.ui.*`
- `data.repository.SessionRepository`
- authenticated shell / session routing introduced in earlier structured-runtime phases

### This phase must **not** touch
- repository/Room/backend contract behavior
- scan queueing logic
- sync semantics
- scanner analysis pipeline
- event operations logic
- attendee search/check-in logic
- broad design-system expansion

---

## What Success Looks Like — End Goal for the Phase

Phase 13 is successful when:

1. the structured authenticated shell has a clear **overflow / burger entry point**
2. logout is available in a clean, predictable way and routes correctly back to the login/session gate
3. operators/support staff can access **permissions troubleshooting** and **diagnostics** without those surfaces being promoted into the main navigation
4. diagnostics remain available, but are clearly framed as **support/admin** information rather than a primary workflow
5. low-frequency controls are discoverable but do not pollute the `Scan`, `Search`, or `Event` destinations
6. no runtime/backend contract boundaries are violated
7. no broad settings framework or vanity preferences system is introduced prematurely

The end state should feel like a proper enterprise scanner product:
- operational paths are clean and direct
- support/admin actions are present but secondary
- the app remains understandable to an operator under pressure

---

## Constraints

### Hard constraints
- Preserve the current Android runtime contract from `architecture.md`
- Preserve projection-only UI/ViewModel boundaries
- No repository / worker / Room / backend contract behavior changes
- No app-shell redesign beyond the already-approved structured shell direction
- No second token system
- No parallel semantic tone enums
- No diagnostics-first UX
- No new backend settings exposed to field operators

### Product constraints
- Overflow must remain **secondary**
- Do not re-elevate diagnostics to a top-level tab
- Do not expose API target/base URL/token-ish infrastructure details in primary operator paths
- Do not let preferences sprawl into a generic settings product with no current value
- Logout must be straightforward and safe
- Permissions troubleshooting must serve the smartphone-first scanning product

### UX constraints
- Support actions should be low-frequency, calm, and obvious
- No feature overload in the overflow menu
- No debug jargon on the main operator routes
- Keep battery/camera recovery messaging simple and action-oriented

### Smartphone-first constraint
This phase must serve the smartphone MVP first. Hardware scanner expansion remains later work. Support surfaces may acknowledge future scanner source differences, but must not co-design the whole support UX around hardware scanners yet.

---

## Worktree Creation

Create a dedicated worktree for Phase 13 before implementation.

### Suggested worktree
- Branch: `codex/phase13-overflow-support`
- Worktree path example: `../FastCheckin-phase13-overflow-support`

### Command pattern
```bash
git worktree add ../FastCheckin-phase13-overflow-support -b codex/phase13-overflow-support
```

If Phase 13 is split into smaller PRs, create one worktree per PR branch.

Recommended PR sequence:
1. overflow shell entry and support destination scaffold
2. logout and permissions troubleshooting
3. diagnostics relocation / controlled diagnostics access
4. preferences only if justified after the first three slices

---

## Detailed Prompts / Tasks / Plans

Phase 13 should be broken into **separate PRs**.

---

# PR 13A — Overflow Entry and Support Destination Scaffold

## Purpose
Create the shell-level overflow entry and the minimal support/admin destination ownership structure without yet widening into full diagnostics redesign.

## What it touches
- authenticated shell overflow button / menu wiring
- destination definitions for support/admin
- minimal `feature/settings/` or `feature/support/` package scaffold

## What success looks like
- overflow entry exists and is reachable from the authenticated shell
- support/admin area has a clear ownership home
- no main-tab pollution
- no diagnostics dump copied blindly into the new shell

## Constraints
- no business logic changes
- no scanner/runtime behavior changes
- no new backend/config features
- no giant settings framework

## Prompt

| Field | Content |
|---|---|
| Task | Add the overflow/support entry point and minimal support destination scaffold for the structured FastCheck Android shell. |
| Objective | Move low-frequency support/admin actions out of the primary operator path while establishing a clean ownership boundary for future overflow surfaces. |
| Output | Shell/menu wiring plus a minimal support destination scaffold under `feature/settings/` or `feature/support/`, without yet implementing the full diagnostics/support experience. |
| Note | Root this in the current repo reality: diagnostics/support data currently live directly in the old shell. Do not elevate diagnostics into main navigation. Do not broaden into settings-system design. Keep this PR structural, narrow, and shell-focused. |

### Tests / validation
- shell navigation tests if the project already has a low-cost pattern for shell-level tests
- at minimum: compile, `git diff --check`, targeted unit tests for any new navigation-state helpers
- no screenshot tests required

---

# PR 13B — Logout and Permissions Troubleshooting Surface

## Purpose
Implement the most important support actions first: logout and smartphone-scanner permission recovery.

## Why this is the right second slice
`SessionRepository` already supports logout, and scanner permission/recovery is already a real runtime concern in `MainActivity` and `ScanningViewModel`. This makes logout and permissions a grounded, high-value support slice.

## What it touches
- support destination UI
- logout action wiring through session boundary
- camera permission troubleshooting / re-request / recovery surface
- scanner readiness/support messaging for smartphone-first operation

## What success looks like
- operator/support user can log out cleanly from overflow
- logout returns the app to the correct unauthenticated state
- smartphone camera permission issues can be understood and retried without surfacing raw system/debug clutter on main tabs

## Constraints
- logout must use the existing session boundary
- no direct token/UI coupling
- no change to scanner queue/network path
- no new debug jargon in operator-facing copy
- hardware-scanner troubleshooting remains deferred unless needed for future-safe wording

## Prompt

| Field | Content |
|---|---|
| Task | Implement logout and smartphone camera-permission troubleshooting in the overflow/support area. |
| Objective | Provide the two highest-value support actions outside the main operator flow: safe session exit and scanner permission recovery. |
| Output | Support destination updates that include logout and a controlled permission-recovery surface, wired through existing session/scanning boundaries. |
| Note | Use `SessionRepository.logout()` for session exit. Root permission UX in the current smartphone-first scanner behavior and the existing permission/readiness state in `ScanningViewModel` / `ScanningUiState`. Do not introduce scanner-source complexity for hardware scanners yet. Keep copy calm and operator-readable. |

### Tests / validation
- targeted tests for any logout routing/session-state helper introduced
- targeted tests for any permission/support-state projection helper introduced
- compile + `git diff --check`
- no screenshot tests required

---

# PR 13C — Controlled Diagnostics Access and Reframing

## Purpose
Keep diagnostics available, but reframe them as a support/admin surface rather than a first-class operator workflow.

## What it touches
- support/admin diagnostics screen or sub-screen
- reuse/refinement of `feature.diagnostics.*`
- possible diagnostics grouping/sectioning for support readability

## What success looks like
- diagnostics are still accessible
- diagnostics are no longer visually/structurally treated as a primary workflow
- event/session/network/support info is readable for support staff without leaking into the operator’s main path

## Constraints
- do not remove useful diagnostics truth
- do not move diagnostics back into primary tabs
- do not invent backend health/config APIs
- do not turn this into a general admin console

## Prompt

| Field | Content |
|---|---|
| Task | Move diagnostics into controlled overflow-owned access and reframe the existing diagnostics projection as a support/admin surface. |
| Objective | Preserve important operational/support truth while removing diagnostics from the primary operator runtime path. |
| Output | Overflow-owned diagnostics access using the existing diagnostics projection/factory as the starting truth source, with calmer structure and clearer support-focused grouping. |
| Note | Ground this in the current `DiagnosticsUiState` and `DiagnosticsUiStateFactory`. Keep event/session/queue/flush truth, but do not treat API target/base URL/token state as operator-primary information. This is controlled access, not deletion and not a new admin product. |

### Tests / validation
- targeted tests only if new diagnostics grouping/projection helpers are introduced
- compile + `git diff --check`
- existing diagnostics tests should still pass

---

# PR 13D — Preferences (Only If Justified)

## Purpose
Add only the minimum preferences surface that has actual runtime value now.

## Important warning
This PR is optional.

Preferences are easy to overbuild. Unless there is a real smartphone-first operational need, this slice should stay tiny or be deferred.

## Acceptable current candidates
- scanner behavior preferences that are truly smartphone-first and supportable
- possibly a battery-related scanner policy toggle only if the approved scanner interaction policy already demands it

## Not acceptable in this phase
- broad settings framework
- environment switching
- backend URLs
- advanced debug toggles for operators
- future hardware-scanner settings as if that product is already here

## Prompt

| Field | Content |
|---|---|
| Task | Add a minimal preferences surface only if a concrete current runtime need exists after overflow, logout, permissions, and diagnostics access are already in place. |
| Objective | Avoid premature settings sprawl while allowing one or two genuinely useful support preferences if the current smartphone-first product already needs them. |
| Output | A very small preferences screen or section under overflow, only if justified by an approved scanner/support policy. |
| Note | Skip this PR entirely unless there is a clear, current, operator-supporting preference that belongs in-product now. Do not add backend, environment, or future hardware-scanner settings. Keep this slice deliberately tiny. |

### Tests / validation
- only test real preference-state logic if it exists
- otherwise compile + `git diff --check`

---

## Robust Tests and Regression Protection

Phase 13 does not need heavy UI/screenshot testing by default. It does need disciplined regression checks where support-state or routing helpers become real logic.

### Test priorities

#### Must test if introduced
- logout routing/session transition helpers
- support/overflow state projection helpers
- permission troubleshooting state helpers
- diagnostics regrouping helpers

#### Must keep passing
- existing auth/session tests
- existing diagnostics tests
- existing scan/sync/queue semantic tests

#### Validation commands
Use the project’s current validation habits:
```bash
git diff --check
JAVA_HOME=/home/jcschoeman96/.jdks/jdk-25.0.2+10 bash ./gradlew -Dorg.gradle.java.home=/home/jcschoeman96/.jdks/jdk-25.0.2+10 :app:compileDebugKotlin :app:testDebugUnitTest
```

### Things not to add unless clearly justified
- screenshot regression suites
- broad UI harness complexity
- snapshot-heavy shell testing
- test-only abstractions that exist solely to satisfy the test layer

---

## Risks and Edge Cases

- logout while queue backlog exists
- session expiry while operator is not on the Scan tab
- permission revoked mid-session
- user reaches support area while offline
- support/diagnostics copy becoming too technical for operator-facing contexts
- overflow menu turning into a dumping ground for every unowned feature
- hardware-scanner concepts leaking into smartphone-first support UX too early

---

## Recommended PR Order

1. **PR 13A** — overflow entry and support destination scaffold
2. **PR 13B** — logout and permissions troubleshooting
3. **PR 13C** — controlled diagnostics relocation/access
4. **PR 13D** — preferences only if clearly justified

This order keeps the shell structure clean first, then adds the highest-value support actions, then rehomes diagnostics, and only then considers preferences.

---

## What to Reject During Implementation

Reject or push back if the coding agent starts doing any of these:
- making diagnostics a primary tab or equal workflow to Scan/Search/Event
- exposing API base URL or backend environment controls to normal operators
- introducing a giant settings framework
- making manual flush the center of support UX
- broadening this phase into hardware-scanner product work
- modifying repository/network/worker behavior
- rewriting scanner pipeline behavior
- adding speculative preferences with no current product value

---

## End Goal Summary

The end goal of Phase 13 is a polished, enterprise-appropriate support/overflow layer where:
- operators stay focused on scanning/search/event work
- support/admin actions remain available but secondary
- logout is easy and safe
- smartphone permission/camera recovery is clear
- diagnostics are accessible without dominating the app
- the product feels deliberate instead of like a debug console
