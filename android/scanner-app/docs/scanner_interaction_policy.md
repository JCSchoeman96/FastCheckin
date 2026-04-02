# Scanner Interaction Policy

## Purpose

This document defines the smartphone-first scanner interaction model for the
future `Scan` destination. It exists to prevent the current temporary shell
from hardening into an always-on camera control panel.

This is a planning document only.

## Current Repo Grounding

The current scanner structure already gives useful boundaries:

- `ScanningViewModel` owns scanner permission and source-status projection.
- `ScannerSourceBinding` owns source start/stop and decoded-value collection.
- `MainActivity` currently decides when scanner binding starts or stops.
- `ScannerSourceActivationPolicy` already gates activation on shell-started
  state and camera permission.
- `ScanCapturePipeline` ends at local queue admission and does not call network
  code directly.

The current runtime also supports more than one scanner source abstraction, but
the product priority is not equal across sources:

- smartphone camera scanning is MVP priority
- DataWedge/hardware compatibility remains future-safe but deferred

## Product Stance

The future `Scan` destination is a smartphone scanning surface first.

That means:

- camera scanning is the primary operator path
- battery behavior is a first-class UX concern
- queue/sync state should support scanning, not replace it
- hardware-scanner specifics are later work and must not distort the first
  runtime policy

## Scanner States

The future `Scan` runtime should use these operator-level states.

### Idle

`Idle` means:

- operator is authenticated
- `Scan` is available
- camera is not actively running
- queue/sync state can still be visible

Examples:

- `Search` or `Event` tab is selected
- app is returning to foreground before `Scan` is resumed
- operator has not yet entered the `Scan` surface

### Armed

`Armed` means:

- operator is on the `Scan` tab
- app is in foreground
- scanner source prerequisites are satisfied
- runtime is ready to start or resume the source cleanly

For the camera path, this is the pre-active ready state after permission is
granted and before or while the preview is about to become live.

### Active

`Active` means:

- `Scan` tab is selected
- app is foregrounded
- permission is granted
- scanner source is running
- camera preview is visible for the smartphone path

This is the only state where continuous camera capture should happen.

### Cooldown

`Cooldown` means:

- the scan pipeline has just accepted a capture for local queue admission
- the short capture throttling window is active
- the scanner remains a scanning surface, but immediate repeated captures are
  intentionally suppressed

`Cooldown` is a scan interaction state, not a battery-management state.

### Blocked

`Blocked` means scanning cannot proceed yet because a prerequisite is missing.

Examples:

- camera permission denied
- scanner source failed to start
- session no longer valid
- app is backgrounded

Blocked states must be actionable and explicit. They must not silently fall
back into a fake ready state.

## Camera Lifecycle Policy

The future product runtime must keep camera ownership narrow.

### Camera May Run Only When

- operator is authenticated
- `Scan` is the active destination
- app is in foreground
- camera permission is granted
- scanner source is healthy

### Camera Must Stop When

- operator leaves the `Scan` destination
- app moves to background
- session is invalidated or logout occurs
- permission is lost or denied
- scanner source enters an error state that requires recovery

### Camera Ownership Rule

Non-`Scan` destinations never own camera lifecycle.

This prevents the future app from carrying the current activity-wide scanner
binding behavior forward into the wrong shell shape.

## Battery Policy

Battery behavior must be explicit, but this phase should not hard-code a future
timeout strategy.

### MVP Battery Control

The first runtime implementation should treat these as the primary battery
controls:

- camera active only on the `Scan` destination
- camera inactive on non-`Scan` destinations
- camera inactive in background
- camera inactive while permission/session prerequisites are not met

### Inactivity Timeout

No mandatory inactivity timeout is required in the first runtime
implementation.

That does not mean inactivity timeout is forbidden forever. It means:

- tab and lifecycle boundaries are the primary battery control for MVP
- inactivity timeout is a later optimization
- Phase 8 should not require a timeout before the structured scanner runtime is
  even in place

## Tab Switching Policy

The tab policy should be simple and strict.

- entering `Scan` is what makes scanner activation eligible
- leaving `Scan` returns scanning to `Idle`
- `Search` and `Event` remain scanner-inactive even if scan-related warnings or
  queue state are visible there

This keeps the camera from becoming a shell-global side effect.

## Background / Foreground Policy

- backgrounded app means scanner inactive
- foreground resume may restore scanner eligibility only if `Scan` is still the
  active destination and prerequisites are still satisfied
- backgrounding must not preserve an active camera session

This aligns with the current lifecycle truth already expressed in
`MainActivity`, `ScannerSourceBinding`, and source activation policy.

## Permission Handling Policy

Permission handling belongs to the `Scan` experience, but it should not distort
the overall runtime hierarchy.

- camera permission messaging is part of `Scan`
- denied permission puts scanning into `Blocked`
- permission recovery can be reached from `Scan`
- overflow may contain a secondary recovery/support path, but it should not own
  the primary permission UX

## Queue / Sync Visibility While Not Actively Scanning

The future `Scan` destination may still show:

- queued-local feedback
- compact upload-state warnings
- auth-expired warnings
- stale-sync warnings

That visibility does not justify keeping the camera active.

Queue and sync state should remain visible even when scanning is `Idle` or
`Blocked`, because operator understanding of capture health matters even when
the preview is not running.

## DataWedge / Hardware Policy

DataWedge and future hardware-scanner support should remain abstraction-safe
but explicitly deferred.

This document therefore locks these rules:

- smartphone camera scanning is the first-class product path
- hardware-specific UX is not co-designed as an equal first priority in Phase 8
- future hardware work must adapt to the product shell that smartphone-first
  implementation establishes, not vice versa

## Rejected Behaviors

This policy rejects:

- always-on camera behavior across the whole authenticated shell
- keeping camera active on `Search` or `Event`
- background camera scanning
- treating cooldown as proof of server-confirmed admission
- letting support/debug controls become the center of the `Scan` experience

## Handoff

This policy should guide implementation as follows:

1. Phase 9 creates the shell and destination ownership model
2. Phase 10 implements the first real smartphone-first `Scan` runtime with the
   lifecycle rules above
3. Hardware-scanner differentiation is deferred until the smartphone runtime is
   stable
