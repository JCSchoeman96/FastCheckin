# AGENTS.md — FastCheck Active Engineering Rules

This repository contains a Phoenix application and an Android scanner application.

Use this file as the active source of truth for coding agents.
Prefer current architectural rules and invariants over old project history or assumptions.

---

## 1) Project truth

FastCheck is an event check-in system with:

- a Phoenix backend and web dashboard
- an Android native scanner app under `android/scanner-app`
- a current mobile runtime pinned to the existing Phoenix mobile API
- a current Android scanner pivot from camera-first toward source-agnostic scanner input

Current Android runtime scope remains intentionally narrow:

- `POST /api/v1/mobile/login`
- `GET /api/v1/mobile/attendees`
- `POST /api/v1/mobile/scans`

The backend remains authoritative for business outcomes.
The Android app captures input, queues scans locally, syncs attendees, uploads scans, and renders operator feedback.

Do not invent new runtime assumptions unless explicitly requested.

---

## 2) Global working rules

- Finish the task fully before stopping.
- Keep changes minimal and incremental.
- Do not rewrite unrelated code.
- Prefer small, reviewable changes over broad refactors.
- Keep the repo truthful: code, docs, and tests must agree.
- If architecture or behavior is unclear, inspect the code first.
- If a rule in this file conflicts with the current codebase, favor the current codebase and update docs/tests to remove drift.
- Add or update tests for every behavior change.
- Do not silently change contracts, payloads, or persistence semantics.
- Use clear naming and small files.
- Add short KDoc or comments where boundaries are not obvious.
- Never leave dead code, fake TODO implementations, or placeholder logic disguised as finished work.

---

## 3) Required verification workflow

### Phoenix / Elixir changes
- Run focused tests first.
- Then run `mix precommit`.
- Fix any pending issues before finishing.

### Android changes
- Run focused tests first.
- Then run `./gradlew :app:testDebugUnitTest` from `android/scanner-app`.

### Cross-cutting rules
- Do not claim a change is complete without verification.
- If a verification step cannot run because of local environment/tooling constraints, state that explicitly and still run every relevant check that is available.

---

## 4) Active Android scanner architecture rules

These rules apply to the current Android scanner source-spine phase.

### 4.1 Folder ownership

- Put source-agnostic scanner contracts in:
  `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/scanning/domain`

- Put source-specific scanner implementations in dedicated source-specific folders under:
  `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/scanning/`

- Put scanner binding/coordinator logic in:
  `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/scanning/usecase`

- Keep scanner UI state and ViewModel logic in:
  `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/scanning/ui`

- Keep queue persistence and upload behavior in the existing:
  `domain`, `data`, and `worker` layers

### 4.2 Boundary rules

- Do not let camera, wedge, or broadcast adapters write directly to:
  - Room
  - repositories
  - WorkManager workers
  - Retrofit clients
  - network APIs

- Do not bypass the existing queue path.
- Do not let source type change queue semantics.
- Do not add a new backend runtime assumption beyond the current Phoenix mobile contract.
- Do not add a new Gradle module for this phase.
- Do not make Intents the internal app-wide scanner contract.
  Intents may exist only at a hardware-adapter edge.

### 4.3 Scanner invariants

- Preserve raw captured values exactly unless the value is blank-only and must be rejected.
- Reject blank-only input, but do not trim, uppercase, normalize separators, or otherwise silently mutate non-blank payloads before queue persistence.
- Keep scanner source failures separate from queue or upload outcomes.
- Keep frame gate, replay suppression, cooldown, and queue semantics as separate concerns.
- The backend remains authoritative for admission outcomes.
- Android runtime direction remains current-contract only. Do not activate future exit/device/gate behavior until backend support exists.

### 4.4 Current implementation priorities

Use this order unless explicitly told otherwise:

1. Raw transport invariant
2. Regression tests
3. Source-agnostic scanner contracts
4. Camera refit onto the shared scanner spine
5. First hardware adapter
6. Source switching and recovery
7. Device-readiness config hardening
8. Docs and contract audit alignment

### 4.5 Android verification standards

- Every scanner behavior change must include new or updated tests.
- Prefer unit tests or Robolectric unless Android framework behavior truly requires instrumentation.
- Focused tests first, then full Android unit suite.
- Runtime contract tests must stay aligned with implemented behavior.

---

## 5) Android scanner implementation constraints

When editing the Android app:

- Keep the app as a single `:app` module for this phase.
- Do not refactor packages just for aesthetics.
- Do not introduce device/session/gate runtime behavior yet.
- Do not merge broadcast and keyboard-wedge support into one first-pass task unless the hardware estate is explicitly fixed and tested.
- Do not place business logic inside scanner adapters.
- Do not place persistence or upload behavior inside scanner UI code.
- Do not place CameraX-specific details into generic scanner domain contracts.

Preferred naming:

- `*InputSource` for source adapters
- `*Coordinator` for ordered scanner orchestration
- `*UiState` for rendering state only
- `*Analyzer` for camera analysis
- `*Pipeline` for capture-to-queue handoff seams

Avoid vague names like:

- `Helper`
- `Bridge`
- `Util`
- `Manager` unless it truly coordinates multiple responsibilities

---

## 6) Phoenix / Elixir project rules

### 6.1 General Elixir rules

- Elixir lists do not support index access via `list[index]`.
  Use `Enum.at/2`, pattern matching, or `List`.

- Variables are immutable but can be rebound.
  If you need the result of `if`, `case`, or `cond`, bind the result outside the block.

- Never nest multiple modules in the same file.

- Never use map access syntax like `changeset[:field]` on structs.
  Use direct field access or the proper API, such as `Ecto.Changeset.get_field/2`.

- Prefer Elixir standard library for date/time handling.
  Do not add extra date/time dependencies unless explicitly needed.

- Never use `String.to_atom/1` on user input.

- Predicate functions should end with `?`.
  Reserve `is_*` names for guards.

- When using OTP primitives like `DynamicSupervisor` and `Registry`, provide explicit names in child specs.

- Use `Task.async_stream/3` for concurrent enumeration when appropriate, usually with explicit options.

### 6.2 Mix rules

- Read task docs before using unfamiliar tasks via `mix help <task>`.
- To debug test failures, run focused files first.
- Avoid `mix deps.clean --all` unless there is a real reason.
- Use `mix precommit` when Elixir/Phoenix changes are complete.

### 6.3 HTTP client rules

- Use the already included `Req` library for HTTP requests.
- Avoid `:httpoison`, `:tesla`, and `:httpc` unless explicitly required.

---

## 7) Phoenix rules

- Be careful with router `scope` aliases.
  Do not duplicate module prefixes.

- Do not create redundant route aliases when the `scope` already provides them.

- Do not use `Phoenix.View`.

### Phoenix 1.8 / LiveView rules

- Begin LiveView templates with the app layout wrapper expected by the project.
- If you hit a missing `current_scope` assign, fix routing/session/layout usage correctly.
- Do not call `<.flash_group>` outside the layouts module.
- Use the imported `<.icon>` component for icons.
- Use the imported `<.input>` component for forms when available.
- If you override input classes, fully style the input yourself.

### JavaScript / CSS rules

- Use Tailwind classes and custom CSS for polished UI.
- Maintain the project’s existing Tailwind setup and import style.
- Do not assume a `tailwind.config.js` is required unless the repo already uses one for a real reason.
- Never use `@apply` in raw CSS.
- Do not add inline `<script>` tags in templates.
- Do not vendor scripts/styles by linking directly in layouts; integrate them through the project asset pipeline.

### UI / UX rules

- Aim for polished, usable UI.
- Prefer clean spacing, good typography, clear hierarchy, and subtle interaction states.
- Add loading, empty, and error states where behavior changes matter.

---

## 8) Phoenix HTML / HEEx rules

- Use `~H` or `.html.heex`, never `~E`.
- Use `Phoenix.Component.form/1` and `inputs_for/1`, never the old Phoenix HTML form helpers.
- Always assign forms with `to_form/2` in LiveView and drive templates from `@form`.
- Always add explicit DOM IDs to key elements.
- For multiple conditional branches, use `cond` or `case`, not `else if`.
- Use `phx-no-curly-interpolation` when showing literal curly braces in code blocks.
- Use HEEx class lists with `[...]`.
- Do not use invalid multi-value class attribute syntax.
- Use `<%= for ... do %>` instead of `Enum.each` in templates.
- Use HEEx comment syntax: `<%!-- comment --%>`.
- Use `{...}` interpolation inside attributes and values, and `<%= ... %>` for block constructs in tag bodies.

---

## 9) LiveView rules

- Do not use deprecated `live_redirect` or `live_patch`.
  Use `<.link navigate={...}>`, `<.link patch={...}>`, `push_navigate`, and `push_patch`.

- Avoid LiveComponents unless there is a strong reason.

- Name LiveViews with the `Live` suffix.

- If a hook manages its own DOM, use `phx-update="ignore"`.

- Never write embedded script tags in HEEx.
  Put hooks and JS in the asset pipeline.

### LiveView streams

- Use LiveView streams for collections where appropriate.
- Use `phx-update="stream"` correctly in templates.
- Do not treat streams like regular enumerables.
- To filter or refresh, refetch and re-stream with `reset: true`.
- Track empty states and counts with separate assigns where needed.
- Never use deprecated `phx-update="append"` or `prepend"`.

### LiveView testing

- Use `Phoenix.LiveViewTest` and `LazyHTML`.
- Prefer `element/2`, `has_element?/2`, and outcome-driven assertions over raw HTML assertions.
- Use explicit DOM IDs from templates in tests.
- When selectors fail, inspect targeted HTML fragments, not whole pages unless necessary.

---

## 10) Ecto rules

- Preload associations when templates or downstream logic will access them.
- Import required Ecto modules explicitly in scripts like `seeds.exs`.
- Use `:string` fields for text-like schema fields unless a different type is actually needed.
- Do not use `validate_number/2` with `:allow_nil`; it is unnecessary.
- Use `Ecto.Changeset.get_field/2` for changeset field reads.
- Fields set programmatically, like ownership or scope fields, must not be blindly cast from user input.
- Be explicit with constraints and indexes when adding new query-critical paths.

---

## 11) Testing rules

- Every behavior change requires test coverage.
- Favor narrow, deterministic tests.
- Test outcomes, not implementation trivia.
- Keep tests small and isolated.
- Add regression tests for bugs that were fixed.
- When a contract changes, update:
  - code
  - tests
  - relevant docs
  - contract audits

For Android runtime contract work specifically:

- Keep contract tests factual and narrow.
- Do not let docs or tests describe future device-session or offline-package behavior as active runtime truth.

---

## 12) Documentation rules

- Keep docs honest and current.
- Do not leave stale claims like “production-ready” or “achieved” unless they are still verified and maintained.
- If a README, audit test, or architecture doc contradicts actual code, fix the drift.
- Do not document future ideas as present behavior.
- Prefer a single current source of truth over duplicated explanations in multiple stale files.

---

## 13) Security and correctness rules

- Do not log secrets, API keys, tokens, or sensitive payloads.
- Do not weaken auth/session boundaries for convenience.
- Do not hide input mutation behind “cleanup” logic.
- Do not silently broaden accepted runtime behavior.
- Be explicit about event scoping, session scoping, and ownership boundaries.
- Keep audit and check-in logic traceable.

---

## 14) What agents must avoid

Do not:

- rewrite whole subsystems when a narrow fix is enough
- mix scanner adapter logic with queue persistence or upload logic
- introduce hidden normalization in scanner payload handling
- hardcode future architecture into today’s runtime
- create new modules or packages just to look cleaner without behavioral benefit
- leave docs/tests stale after changing behavior
- make claims of completion without running verification

---

## 15) Preferred response style for coding agents

When proposing or implementing changes:

- state what changed
- state why it changed
- state where it changed
- state how it was verified
- call out anything not verified due to environment constraints

Be direct. Be precise. Do not hand-wave.

---