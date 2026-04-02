# Phase 9 — Session Gate and Authenticated Shell Scaffold

## Double-check of the plan

This Phase 9 plan is rooted in the current `main` branch state and the actual Android runtime shape.

### Repo-grounded truths

- The Android runtime contract is still intentionally narrow:
  - `POST /api/v1/mobile/login`
  - `GET /api/v1/mobile/attendees`
  - `POST /api/v1/mobile/scans`
- Android remains local-first, backend-authoritative, and UI/ViewModels must stay projection-only.
- Auto-flush is the normal upload path; manual flush remains fallback/debug.
- The current live runtime is still a single `MainActivity` plus one long XML/ViewBinding shell.
- The current shell mixes login, sync, scanner, manual queue, and diagnostics in one screen.
- Compose is enabled in the app, but there is no existing runtime navigation package and no `navigation-compose` dependency on `main`.
- Smartphone camera scanning is the MVP and first priority. Hardware-scanner-specific UX expansion is explicitly deferred.

### What this means for Phase 9

Phase 9 must **not** try to implement the full product.
It must build the **runtime skeleton** that makes the later product possible, while preserving current working behavior.

That means:

- split unauthenticated login from authenticated runtime
- create the authenticated shell structure
- introduce the `Scan / Search / Event` product information architecture
- keep the current operator flow usable by temporarily containing the legacy runtime inside the new shell
- reduce `MainActivity` responsibility without rewriting Phase 10 scanning, Phase 11 search, or Phase 12 event operations yet

Phase 9 is therefore **not** the real Scan screen implementation phase.
It is the **session and shell architecture phase**.

---

## Phase description

Phase 9 introduces the first real product runtime structure:

1. **Unauthenticated login gate**
2. **Authenticated shell**
3. **Bottom navigation**
   - `Scan`
   - `Search`
   - `Event`
4. **Overflow / burger**
   - lower-priority support actions only
5. **Temporary legacy scan bridge**
   - the current all-in-one operator shell remains temporarily accessible only through the new authenticated structure so the app stays functional while the structured product is built in later phases

This phase should reduce architectural risk, not increase it.

---

## What this phase touches

### Existing files likely touched

- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/app/MainActivity.kt`
- `android/scanner-app/app/src/main/AndroidManifest.xml` *(only if routing/activity structure truly requires it)*
- `android/scanner-app/app/src/main/res/layout/activity_main.xml` *(only if minimal containment changes are unavoidable; avoid broad edits)*

### Existing feature areas referenced but not widened

- `feature/auth/*`
- `feature/scanning/*`
- `feature/queue/*`
- `feature/sync/*`
- `feature/diagnostics/*`

### New packages/folders likely introduced

- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/app/session/`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/app/navigation/`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/app/shell/`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/app/legacy/` *(or similarly named package for legacy operator-shell containment only if needed)*

### New responsibilities introduced

- session-aware runtime route selection
- authenticated shell state and destination model
- overflow action model
- temporary bridge from new shell to current operator surface

---

## What success looks like

Phase 9 is successful when all of the following are true:

1. The app no longer treats login and the operator runtime as one giant screen.
2. There is a clear split between:
   - unauthenticated login
   - authenticated app shell
3. The authenticated shell has exactly three primary destinations:
   - `Scan`
   - `Search`
   - `Event`
4. Overflow exists for lower-priority actions and does **not** elevate diagnostics into primary navigation.
5. The app remains usable after the phase:
   - operators can still login
   - operators can still reach the current working runtime path through the new shell
6. `MainActivity` is less overloaded than before.
7. No repository, worker, Room, scanner-analysis, or backend contract behavior changes are introduced.
8. No false product completion is claimed:
   - real Scan screen UX remains Phase 10
   - real Search/manual check-in remains Phase 11
   - real Event operations remains Phase 12

### End goal for the phase

A stable runtime skeleton that allows later product work to land cleanly without continuing to grow the single-screen XML control panel.

---

## Constraints

These are hard rules for Phase 9.

### Product constraints

- Smartphone camera scanning is the MVP and first priority.
- Hardware-scanner-focused UX must remain deferred until later phases.
- Operators should not be exposed to base URL, API target, or backend-ish setup details.
- Sync/flush must move toward system-managed behavior, not operator-managed behavior.
- Diagnostics, debug, permissions troubleshooting, preferences, and logout must remain secondary.

### Architecture constraints

- Respect `android/scanner-app/docs/architecture.md`.
- Preserve current runtime contract:
  - login
  - attendees
  - scans
- Scanner analysis must never call network code directly.
- UI/ViewModels remain projection-only over repository/Room/coordinator truth.
- Auto-flush remains normal; manual flush remains fallback/debug.
- Do not invent new backend endpoints or richer attendee/server capabilities in this phase.

### Runtime constraints

- Do not implement the final Scan screen in this phase.
- Do not implement the full Search/manual check-in feature in this phase.
- Do not implement the full Event operations screen in this phase.
- Do not add `FcBadge`.
- Do not add a second theme or component system.
- Do not force hardware-scanner UX compromises into the smartphone-first runtime now.

### Dependency constraints

- Prefer **not** adding `navigation-compose` in this phase unless there is a clear technical reason.
- Because the repo already has Compose enabled but no existing runtime navigation library, Phase 9 should prefer a minimal shell-state model first.
- Do not add dependencies casually.

### Refactor constraints

- Do not leave `MainActivity` as the final long-term owner of all runtime concerns.
- But also do not do a giant rewrite in one PR.
- Keep the current operator flow reachable while the shell is introduced.

---

## Worktree creation

Use one worktree per PR slice.

### PR 9A
```bash
git fetch origin
git worktree add ../fastcheck-phase9a -b codex/phase9-session-gate origin/main
```

### PR 9B
```bash
git fetch origin
git worktree add ../fastcheck-phase9b -b codex/phase9-authenticated-shell origin/main
```

### PR 9C
```bash
git fetch origin
git worktree add ../fastcheck-phase9c -b codex/phase9-legacy-runtime-extraction origin/main
```

### Suggested PR titles

- `# Phase 9A`
  - `[codex] phase 9 session gate`
- `# Phase 9B`
  - `[codex] phase 9 authenticated shell`
- `# Phase 9C`
  - `[codex] phase 9 legacy runtime extraction`

---

## Detailed phase breakdown

---

## PR 9A — Session gate and runtime route split

### What this PR is

The first runtime-structure PR.

It creates a clear boundary between:

- **Logged-out / unauthenticated**
- **Logged-in / authenticated**

This is the minimum structural step needed before the product can become a real scanner app instead of one long mixed shell.

### What this PR touches

Likely touches:

- `app/MainActivity.kt`
- new files under `app/session/`
- possibly a minimal shell route model under `app/navigation/` or `app/shell/`
- existing auth feature integration points only as needed

### What success looks like

- There is an explicit runtime route model.
- The app can determine whether to show:
  - login gate
  - authenticated shell entry
- Login is no longer treated as just the top section of a giant all-in-one screen.
- No actual Scan/Search/Event product surfaces are claimed complete yet.
- No backend or repository behavior changes are introduced.

### Recommended design

Prefer a small, testable route model such as:

- `LoggedOut`
- `Authenticated`

And, if needed, internal transitional states such as:
- `RestoringSession`
- `AuthError`

Do **not** make routing depend on random UI labels or view visibility.

Base it on session truth and app shell state.

### Constraints

- Do not implement bottom nav here yet unless a tiny stub is needed.
- Do not implement Search/Event screens here.
- Keep login fields aligned with current auth truth:
  - `eventId`
  - `credential/password`
- Do not surface base URL/API target in the operator path.

### Robust tests

Add focused tests for route decision logic.

Suggested tests:
- no session -> unauthenticated route
- valid session -> authenticated route
- no false authenticated route when login fails
- route logic remains independent of view rendering

Prefer pure unit tests first.
Use Robolectric only if a host/activity routing decision cannot be kept pure.

### Prompt / task for Codex

| Field | Content |
|---|---|
| Task | Implement the runtime session gate and route split for the Android scanner app so unauthenticated login and authenticated runtime no longer live inside the same mixed shell. |
| Objective | Establish the minimum runtime architecture boundary needed for the structured product: a real login gate and a distinct authenticated entry path. |
| Output | New files under `app/session/` and any minimal `MainActivity` changes needed to route between unauthenticated and authenticated runtime states without changing repository/backend behavior. |
| Note | Root this in the current auth model and session truth. Keep operator login as event ID + password only. Do not implement the final shell, Scan screen, Search screen, or Event screen here. Do not invent backend capabilities. Keep the routing decision small, explicit, and testable. |

---

## PR 9B — Authenticated shell scaffold

### What this PR is

The product-shell PR.

It introduces the authenticated runtime structure:

- bottom nav
- destination model
- overflow action model

But it does **not** implement the final feature screens yet.

### What this PR touches

Likely touches:

- new files under `app/navigation/`
- new files under `app/shell/`
- shell destination/stub screen definitions
- possible minimal Compose host scaffolding if that is the approved route
- no domain/repository logic changes

### What success looks like

- The authenticated shell exists.
- It has exactly three primary destinations:
  - `Scan`
  - `Search`
  - `Event`
- It has an overflow menu for lower-priority actions.
- `Scan` is the default destination.
- `Search` and `Event` can still be structured stubs in this phase.
- Diagnostics are not promoted to primary bottom-nav status.
- No final product claims are made for destination content yet.

### Recommended design

Prefer a small shell model:

- `AppShellDestination.Scan`
- `AppShellDestination.Search`
- `AppShellDestination.Event`

And a separate overflow action model such as:
- `Preferences`
- `Permissions`
- `Diagnostics`
- `Logout`

Do not make diagnostics a tab.

### Constraints

- Do not implement full Search/manual check-in here.
- Do not implement full Event operations here.
- Do not build a large navigation framework if a smaller shell-state model is enough.
- Prefer not to add `navigation-compose` unless there is a clear need.
- Do not expose API target/base URL in bottom-nav destinations.

### Robust tests

Add focused tests for shell state and destination ordering.

Suggested tests:
- default destination is `Scan`
- shell destination order is stable
- overflow actions stay out of bottom nav
- destination selection logic is deterministic
- no diagnostics tab regression

Prefer pure unit tests over UI harness tests.

### Prompt / task for Codex

| Field | Content |
|---|---|
| Task | Implement the authenticated shell scaffold for the Android scanner product with `Scan`, `Search`, and `Event` as primary destinations and lower-priority actions in overflow. |
| Objective | Establish the permanent product information architecture before full feature implementations land. |
| Output | New shell/navigation files under `app/navigation/` and `app/shell/`, plus the minimal runtime hosting changes needed to show the authenticated shell after login. |
| Note | `Scan` must be the default destination. `Search` and `Event` may be structured stubs. Overflow must contain lower-priority items such as preferences, permissions troubleshooting, diagnostics, and logout. Do not turn diagnostics into a primary destination. Do not implement full feature workflows here. Keep the shell small, explicit, and testable. |

---

## PR 9C — Legacy runtime extraction and Scan-tab bridge

### What this PR is

The containment PR.

This is the PR that keeps the app usable while the new shell exists.

It extracts the old monolithic runtime ownership out of `MainActivity` and places the current working operator content behind a temporary **legacy Scan bridge**.

This prevents Phase 9 from breaking the current workflow while still moving architecture forward.

### What this PR touches

Likely touches:

- `app/MainActivity.kt`
- new files under `app/legacy/` or similar containment package
- legacy binding/controller/orchestration helpers
- shell wiring so the current runtime is reachable from the new `Scan` destination temporarily

### What success looks like

- `MainActivity` is less overloaded.
- The old operator shell is no longer treated as the product structure.
- The current working scanning/login/runtime path still functions through the new shell.
- Search/Event remain stubs if Phase 10+ work is not yet done.
- The app does not regress into a broken shell with dead tabs and no usable scan path.

### Recommended design

Extract legacy responsibilities into a dedicated controller/coordinator layer rather than keeping all UI binding inside `MainActivity`.

Possible responsibilities to move out:
- binding render groups
- section-specific render logic
- listener wiring helpers
- legacy scan/sync/diagnostics section orchestration

Keep business logic in existing ViewModels and repositories.
This is a runtime-ownership cleanup, not a domain rewrite.

### Constraints

- Do not redesign the legacy operator surface in this PR.
- Do not start implementing the final Scan screen here.
- Do not change scanner domain/usecase/backend behavior.
- Do not widen into Search/Event implementation.

### Robust tests

Use targeted regression tests to keep the temporary bridge honest.

Suggested tests:
- authenticated shell still reaches the temporary scan bridge
- route/default-destination behavior remains correct
- extracted host/controller logic does not break the current operator path
- compile + existing unit-test suite remain green

Use Robolectric only where host/activity behavior must be validated.
Keep tests scoped to runtime containment, not visual design.

### Prompt / task for Codex

| Field | Content |
|---|---|
| Task | Extract the current monolithic operator runtime ownership out of `MainActivity` and contain the existing working operator surface behind a temporary Scan-destination bridge inside the new authenticated shell. |
| Objective | Keep the app usable while the structured product shell lands, without pretending the old XML operator control panel is the final product. |
| Output | Reduced `MainActivity` responsibilities, new legacy containment/controller files, and shell wiring that routes the authenticated `Scan` destination to the temporary legacy operator surface until the real Scan screen lands in Phase 10. |
| Note | This is a containment/refactor slice, not a full Scan-screen implementation. Preserve current repositories, ViewModels, scanner usecases, and backend contract behavior. Do not implement Search/Event feature flows here. Do not redesign the legacy operator surface. Keep the bridge explicit and temporary. |

---

## Phase-level validation

Run these on each PR slice unless the touched scope clearly justifies a narrower targeted subset:

```bash
git diff --check
JAVA_HOME=/home/jcschoeman96/.jdks/jdk-25.0.2+10 bash ./gradlew -Dorg.gradle.java.home=/home/jcschoeman96/.jdks/jdk-25.0.2+10 :app:compileDebugKotlin :app:testDebugUnitTest
```

### Additional testing guidance

#### For PR 9A
- add route decision unit tests
- avoid UI harness tests unless routing cannot stay pure

#### For PR 9B
- add destination-model and overflow-model unit tests
- avoid premature navigation UI testing

#### For PR 9C
- add targeted regression tests around host/bridge behavior only if needed
- Robolectric is acceptable where activity/shell containment must be verified

---

## What Phase 9 must not do

Reject or push back if implementation starts doing any of these:

- turning diagnostics into a primary destination
- exposing base URL or API target to operators
- making manual flush a primary central CTA
- implementing the full Scan screen here
- implementing full attendee search/manual check-in here
- implementing full Event operations here
- adding `FcBadge`
- inventing new backend endpoints
- changing repository/domain/network/worker behavior
- designing around hardware scanners as equal first priority
- leaving the current `MainActivity` monolith untouched while merely wrapping it cosmetically

---

## Hand-off to Phase 10

Phase 9 should end with:
- session gate
- authenticated shell
- default `Scan` destination
- temporary legacy scan bridge
- shell/runtime ownership ready for the real smartphone-first Scan screen

That sets up Phase 10 cleanly:
- real Scan destination
- smartphone battery-aware camera session behavior
- queue/sync state surfaced correctly
- operator-first scan UX

---

## Final success statement

If Phase 9 is done correctly, the app will still work, but it will no longer be architected like a temporary one-screen internal control panel.

It will instead have:

- a real login gate
- a real authenticated shell
- correct product information architecture
- a contained temporary legacy operator surface
- a clean runway for Phase 10, 11, and 12

That is the right end state for this phase.
