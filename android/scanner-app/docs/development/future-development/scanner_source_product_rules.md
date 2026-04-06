# Scanner Source Product Rules

## Purpose

This document defines product rules for scanner-source-specific behavior in the
future FastCheck Android runtime.

The goal is to keep source-aware runtime work product-led instead of adapter-led.
The fact that multiple sources implement `ScannerInputSource` does not mean they
should be treated as identical operator experiences.

This is a future-development policy document only. It does not authorize
runtime code changes on its own.

## Product Baseline

Smartphone camera scanning remains the reference operator experience.

That means:

- the default operator story is still smartphone-first
- the `Scan` destination is designed around visible capture readiness and
  battery-aware lifecycle ownership
- future hardware support must fit inside the same queue, auth, and admission
  truth model
- hardware support must not force the smartphone path to adopt enterprise
  scanner assumptions prematurely

## Current Repo Grounding

These rules build on existing repo behavior:

- `scanner_interaction_policy.md` already defines the smartphone path as the
  MVP scanning model
- `operator_sync_flush_policy.md` already keeps queue and flush status in a
  supporting role instead of making scanner plumbing the primary operator task
- `ScanningViewModel` already distinguishes camera and DataWedge permission and
  readiness messaging
- `ScanDestinationPresenter` already hides preview-specific UI when the active
  source is not `CAMERA`

The app is already source-aware enough that future implementation should extend
policy deliberately rather than improvising it in UI code.

## Shared Product Truth

These rules must stay true for every source mode.

- source type does not change business truth
- source type does not change queue truth
- source type does not change auth truth
- source type does not change upload truth
- source type does not create a second token or session model
- source type does not create a second vocabulary for duplicate, queued,
  uploaded, offline, or failed results

In every supported mode:

- captures still queue locally first
- backend admission still happens later through the existing mobile upload path
- local capture feedback still must not imply server-confirmed admission
- auto-flush remains normal
- manual flush remains fallback and support

## Smartphone Camera Product Rules

### Camera mode is explicit

Camera scanning is an explicit scanning mode, not a shell-global background
capability.

It should feel like:

- the operator enters `Scan`
- the app becomes scan-ready
- the operator can see that the preview is active
- leaving that surface removes camera ownership

It should not feel like:

- the whole authenticated shell is secretly still running the camera
- switching tabs keeps the scanner effectively active
- backgrounding preserves a live capture session

### Camera mode is battery-aware

Camera scanning is the source mode with the highest app-owned battery cost.

Product policy therefore requires:

- camera active only when the `Scan` destination owns scanning
- camera inactive on non-`Scan` destinations
- camera inactive in background
- camera inactive when permission, auth, preview, or source-health
  prerequisites fail

Future implementation may refine battery policy later, but it must not weaken
these baseline ownership rules.

### Permission UX is part of the product

Camera permission is not a support-only concern. It is a core operator path
concern because the camera path cannot work without it.

Product rules:

- permission requests should remain tied to the operator's scanning intent
- rationale should be understandable and feature-scoped
- denied permission must produce an explicit blocked state
- the app should degrade gracefully instead of pretending the scanner is ready
- support or overflow may help with recovery, but primary permission recovery
  still belongs to the scan experience

### Tab switching and backgrounding pause camera work

Camera mode should stop or pause active scanning eligibility when:

- the operator leaves the `Scan` destination
- the app backgrounds
- the session is invalidated
- permission is denied or revoked
- preview prerequisites are lost

This rule exists to protect both trust and battery life.

## DataWedge / Hardware Product Rules

### No camera permission path

DataWedge-style broadcast scanner mode must not inherit camera-permission UX
just because the app also supports a camera source.

Product rules:

- no camera permission messaging for DataWedge mode
- no preview-driven readiness model
- no fake camera recovery affordances when the active source is broadcast-based

### Hardware readiness can feel different

DataWedge mode may be treated as more continuously ready than camera mode, but
that does not mean it becomes shell-global or bypasses session and destination
rules.

Allowed differences:

- readiness can be described without preview
- the workflow can assume a hardware trigger instead of touchscreen framing
- operator feedback can focus on capture acceptance and source health rather
  than preview state

Disallowed differences:

- scanning outside authenticated/session-valid shell state
- bypassing local queue handoff
- bypassing backend admission
- making support provisioning failures invisible

### Hardware-trigger-friendly workflow may differ

Future DataWedge productization may need a workflow that is friendlier to
rapid hardware-trigger use than the camera path.

That can include:

- status copy that emphasizes readiness over preview
- reduced preview-centric UI
- clearer support diagnostics for provisioning problems

That must not include:

- a different truth model
- different operator semantics for scan outcomes
- a second operational flow that confuses queue or upload status

### Battery expectations differ from camera mode

DataWedge mode should not be forced into camera-style battery messaging.

Product stance:

- the app-owned battery cost is lower because camera preview and analysis are
  not continuously running
- lifecycle and support diagnostics still matter
- lower battery cost does not justify looser auth or shell ownership rules

## Cross-Source Rules

The operator experience can differ by source type, but these rules must remain
stable.

### Source type must not change scan meaning

These operator outcomes must mean the same thing across source types:

- `Queued locally`
- offline backlog
- duplicate suppression
- uploaded
- retry pending
- auth expired
- server failure

### Source type must not create a second auth system

No source mode should introduce:

- device-specific auth for the current runtime
- alternate session tokens
- source-specific backend endpoints
- source-specific admission logic

### Source type must not move support burden into the main workflow

Hardware support will likely need more provisioning, diagnostics, and
support/admin visibility than camera mode.

That complexity should remain mostly outside the main operator path.

The main operator path should stay focused on:

- scan readiness
- latest capture feedback
- attendee readiness
- upload confidence warnings when needed

## Future Support And Admin Rules

### Source selection stays out of the primary operator workflow

Source selection should remain deployment-owned or support-owned unless a later
product decision explicitly changes that.

That means:

- no operator source picker by default
- no operator expectation that they should understand scanner transport mode
- no scanner-source complexity bleeding into routine event operation

### Source information may appear later in support surfaces

It is reasonable for future support/admin surfaces to expose:

- active source type
- provisioning expectations
- source health diagnostics
- hardware profile status or checklist information

It is not reasonable to put that complexity at the center of ordinary scanning.

## Rejected Product Shapes

This policy rejects:

- treating camera and DataWedge as identical UX because both implement the same
  source interface
- allowing hardware support to distort the smartphone-first `Scan` experience
- making source type alter auth, queue, or admission truth
- moving source selection into the operator's normal event workflow
- turning support diagnostics into the main scanning experience
- making preview-oriented UI mandatory for non-camera sources

## Handoff To Future Implementation

Future implementation work should use these rules as decision constraints.

That work should produce:

- source-aware status and readiness behavior
- source-aware support diagnostics
- source-aware lifecycle ownership

That work should not revisit these already-locked decisions:

- smartphone remains the product baseline
- DataWedge is the first hardware expansion path
- source type changes runtime policy, not business truth
- operator semantics for outcomes remain consistent across sources

## References

- `android/scanner-app/docs/scanner_interaction_policy.md`
- `android/scanner-app/docs/operator_sync_flush_policy.md`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/scanning/ui/ScanningViewModel.kt`
- `android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/scanning/screen/ScanDestinationPresenter.kt`
- `https://developer.android.com/training/permissions/requesting`
- `https://techdocs.zebra.com/datawedge/latest/guide/output/intent/`
