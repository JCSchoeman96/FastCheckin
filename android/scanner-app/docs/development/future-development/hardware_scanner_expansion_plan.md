# Hardware Scanner Expansion Plan

## Purpose

This document explains how the FastCheck Android scanner app should expand from
the current smartphone-first runtime into future dedicated scanner hardware
support without weakening the current operator experience or changing runtime
truth boundaries.

This is a future-development document only. It does not authorize runtime code,
API, or shell behavior changes by itself.

## Why This Plan Exists

FastCheck already contains real scanner-source seams:

- `ScannerSourceType` already distinguishes `CAMERA`, `KEYBOARD_WEDGE`, and
  `BROADCAST_INTENT`.
- `ScannerInputSource` already isolates source capture from queueing, network,
  and persistence work.
- `CameraScannerInputSource` already implements the smartphone path.
- `DataWedgeScannerInputSource` already implements the first broadcast-intent
  hardware adapter path.
- `ScannerSourceBinding` already forwards source captures into the existing
  decode and queue handoff path.
- `ScannerSourceSelectionResolver` and `BuildConfig.SCANNER_SOURCE` already
  make source selection a deployment decision rather than an operator-facing UI
  choice.
- `MainActivity` already gates activation around auth state, shell destination,
  permission state, and preview availability.

That means hardware support is not speculative. The repo already has the
minimum seam structure needed for a deliberate product expansion. The work that
remains is productization, source-aware runtime policy, and support boundary
definition.

## Scope Boundaries

This plan keeps the current runtime contract unchanged.

- Active Phoenix endpoints remain:
  - `POST /api/v1/mobile/login`
  - `GET /api/v1/mobile/attendees`
  - `POST /api/v1/mobile/scans`
- Scanner sources continue to emit captures into local queue handoff only.
- The backend remains the authority for check-in admission and business rules.
- Auto-flush remains normal; manual flush remains fallback and support.
- No source path gets a special auth, queue, or upload contract.

This plan does not include:

- new Android runtime code
- new backend endpoints
- alternate device-session auth
- new Room schema
- a keyboard-wedge implementation
- operator-facing source selection UI

## Current Repo Grounding

### Architecture truth

`android/scanner-app/docs/architecture.md` locks the active runtime contract,
the local-first queue-and-flush model, and the rule that Android does not
depend on future `/api/v1` device-session scaffolding.

### Scanner interaction truth

`android/scanner-app/docs/scanner_interaction_policy.md` already defines the
smartphone camera path as the MVP reference UX and rejects always-on
camera-shell behavior.

### Scanner pipeline truth

`android/scanner-app/docs/scanner_pipeline.md` locks the boundary:

- source capture
- decode handoff
- cooldown
- local queue admission
- later upload

No source path is allowed to call the network directly from analysis or capture
handling.

### DataWedge contract truth

`android/scanner-app/docs/datawedge_source_contract.md` already makes three
important product decisions:

- v1 source choice is deployment-owned
- Zebra DataWedge is the first hardware adapter
- keyboard wedge is deferred

### Current source-aware shell behavior

The current shell already reflects meaningful source differences:

- `ScannerShellSourceMode.CAMERA` requires camera permission
- `ScannerShellSourceMode.DATAWEDGE` does not
- `ScanningViewModel` already uses different status and permission copy for
  camera vs DataWedge
- `ScanDestinationPresenter` already hides the camera preview when the active
  source is not `CAMERA`

The future work is therefore not "add source awareness." It is "extend the
current source awareness into a stable product policy."

## Product Baseline

Smartphone camera scanning remains the baseline product path.

That baseline means:

- the primary operator workflow is still touch-first smartphone scanning
- camera permission UX must remain explicit and understandable
- battery behavior remains a first-class concern
- the `Scan` destination remains the main operator scanning surface
- hardware support must adapt to the shell and truth model already built around
  the smartphone-first runtime

Hardware support is an expansion path, not a co-equal MVP target.

## Planned Source Modes

### `CAMERA`

This remains the reference mode.

Characteristics:

- smartphone preview-based scanning
- runtime camera permission required
- source availability tied to foreground lifecycle and the `Scan` destination
- highest battery sensitivity of all planned source modes
- strongest operator-facing visual affordance because preview is visible

### `BROADCAST_INTENT`

This is the first hardware expansion path and maps to Zebra DataWedge-style
broadcast delivery.

Characteristics:

- no camera permission path
- no preview requirement
- scanner trigger and readiness model can feel more "always armed" than camera
- enterprise device provisioning and profile configuration matter more than
  in-app camera UX
- support and diagnostics requirements are higher than on the camera path

This is the next implementation priority after the smartphone runtime is proven
stable.

### `KEYBOARD_WEDGE`

This remains an explicitly deferred future path.

Characteristics:

- already represented in `ScannerSourceType`
- not currently selectable through `ScannerShellSourceMode`
- no current source implementation in the app
- likely different focus, input, and accidental-capture risks than camera or
  broadcast-intent hardware

This path should not be productized until the camera baseline and DataWedge
path are stable enough to justify it.

## Shared Invariants Across All Source Types

These rules must stay identical regardless of source:

- source capture does not equal backend-confirmed admission
- source adapters emit source facts only
- queue durability still happens before acknowledgement to the operator
- backend admission still happens through `POST /api/v1/mobile/scans`
- replay suppression, upload orchestration, and server-result classification
  remain source-independent
- source type must not create a second auth or session model
- source type must not create a second operator truth vocabulary

Operationally, every supported source must still flow through:

1. source emits raw capture
2. existing decode/capture handoff path runs
3. local queue admission happens
4. auto-flush or retryable background flush uploads later
5. backend classifies the result

## Source-Specific Behavior Categories

Source type does not change business truth, but it does change runtime
behavior. Future implementation should treat the following categories as
source-aware.

### Activation model

Camera mode:

- should activate only when the `Scan` destination owns scanning
- should stop when the operator leaves `Scan`, loses permission, logs out, or
  backgrounds the app

Broadcast-intent mode:

- may be treated as source-ready without preview
- still must respect authenticated shell and destination ownership rules
- should not silently become shell-global just because the hardware trigger is
  external to the touchscreen

### Permission model

Camera mode:

- requires runtime camera permission
- needs explicit rationale and graceful degraded behavior when denied

Broadcast-intent mode:

- does not require the camera permission
- relies more on support-side provisioning than runtime user permission prompts

Keyboard wedge, if later implemented:

- likely does not need camera permission
- may introduce focus/input ownership issues that need separate policy

### Foreground and background behavior

Camera mode:

- background means inactive
- preview loss means inactive or blocked
- lifecycle ownership stays tight to the visible `Scan` surface

Broadcast-intent mode:

- no preview requirement
- may feel more continuously available while foregrounded
- still must not bypass session validity, shell state, or support visibility

### Battery expectations

Camera mode:

- highest battery cost because preview and analysis run continuously
- lifecycle gating is the first battery control

Broadcast-intent mode:

- lower app-owned battery pressure because the app is not driving the camera
  preview pipeline
- still requires careful receiver lifecycle and support diagnostics

### Operator-facing affordances

Camera mode:

- preview is meaningful and user-visible
- permission recovery is part of normal operator workflow

Broadcast-intent mode:

- preview is not the center of the experience
- operator status should emphasize readiness and capture handoff, not camera
  state
- support messaging should help confirm provisioning and profile health without
  pushing DataWedge complexity into the normal operator path

## Best-Practice Constraints That Future Work Must Respect

Future implementation should stay aligned with current platform guidance.

### Android permission guidance

Camera permission requests should remain feature-scoped, explained to the user,
and degrade gracefully when denied. This fits the existing smartphone-first
policy better than any shell-global permission strategy.

### CameraX and ML Kit guidance

The camera path should continue to favor bounded real-time analysis work, keep
preview ownership narrow, and avoid turning scanner preview into a
background-capable or shell-global subsystem.

### WorkManager guidance

Retryable upload behavior should continue to live in the existing local queue
and WorkManager path when persistence beyond the active screen or process is
required. Hardware support does not justify moving upload responsibility into
scanner adapters.

### Zebra DataWedge guidance

The first enterprise hardware path should continue to rely on app-associated
profiles and intent delivery rather than treating keystroke-style delivery as
the default abstraction.

## What Must Remain Deferred

The following decisions should stay deferred until the smartphone runtime is
stable in real operator use:

- whether keyboard wedge support is necessary at all
- whether DataWedge support needs extra support/admin setup screens
- whether later settings surfaces should expose source identity or source
  diagnostics to admins
- whether a future hardware deployment needs device-specific operational
  dashboards or provisioning runbooks inside the app
- whether inactivity timeout should differ between camera and hardware-triggered
  devices

Deferring these decisions protects the current MVP from accumulating hardware
policy too early.

## Future Implementation Order

### Phase 1: stabilize the smartphone baseline

Finish and validate the smartphone-first shell/runtime behavior as the
reference product path.

Exit criteria:

- `Scan` destination lifecycle is correct
- queue and upload truth are stable
- permission handling is clear
- operator semantics are trustworthy

### Phase 2: productize DataWedge support

Promote the existing broadcast-intent seam into a supportable product path.

Focus areas:

- source-aware readiness and status copy
- support diagnostics and provisioning expectations
- shell behavior differences where preview is not relevant
- confidence that capture, queue, flush, and admission truths remain unchanged

### Phase 3: evaluate keyboard wedge only if justified

Treat `KEYBOARD_WEDGE` as a later decision, not an assumed next step.

Only proceed if:

- there is a real hardware need that DataWedge does not cover
- input/focus risks are understood
- operator workflow costs are acceptable

## Decision Summary

This plan locks the following decisions:

- smartphone camera remains the product reference UX
- DataWedge is the first hardware expansion path
- keyboard wedge stays deferred
- source type changes shell/runtime policy, not business truth
- queue/admission/auth truth remain shared across all sources
- future hardware support must layer on top of the existing smartphone-first
  shell and queue model, not replace it

## References

- `android/scanner-app/docs/architecture.md`
- `android/scanner-app/docs/scanner_interaction_policy.md`
- `android/scanner-app/docs/scanner_pipeline.md`
- `android/scanner-app/docs/operator_sync_flush_policy.md`
- `android/scanner-app/docs/datawedge_source_contract.md`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/scanning/domain/ScannerSourceType.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/scanning/domain/ScannerInputSource.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/scanning/usecase/ScannerSourceBinding.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/app/scanning/ScannerSourceSelection.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/app/MainActivity.kt`
- `https://developer.android.com/training/permissions/requesting`
- `https://developer.android.com/media/camera/camerax/analyze`
- `https://developers.google.com/ml-kit/vision/barcode-scanning/android`
- `https://developer.android.com/develop/background-work/background-tasks/persistent`
- `https://techdocs.zebra.com/datawedge/latest/guide/api/setconfig/`
- `https://techdocs.zebra.com/datawedge/latest/guide/output/intent/`
