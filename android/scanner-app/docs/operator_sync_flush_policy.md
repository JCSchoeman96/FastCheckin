# Operator Sync And Flush Policy

## Purpose

This document defines what operators should and should not need to think about
for attendee sync, queue depth, and scan flush behavior in the future product
runtime.

The goal is to move sync/flush away from the center of the product and keep it
system-managed except when intervention is actually needed.

This is a planning document only.

## Current Repo Grounding

The current Android runtime already establishes important truth boundaries:

- attendee sync is driven by `SyncRepository` and persisted sync metadata
- queue admission is local-first through `QueueCapturedScanUseCase` and
  `MobileScanRepository`
- upload orchestration is owned by `AutoFlushCoordinator`
- latest flush summary and recent server outcomes are persisted locally
- diagnostics project repository/Room truth plus coordinator state

The current runtime also already auto-flushes from these triggers:

- `AfterEnqueue`
- `ConnectivityRestored`
- `ForegroundResume`
- `PostLogin`
- `PostSync`

Manual flush still exists, but the architecture truth is already that
auto-flush is normal and manual flush is fallback/debug.

## Product Principle

Operators should think about scanning first, not plumbing first.

That means:

- sync and flush should mostly happen without operator intervention
- the product should surface status and warnings, not force operators to manage
  queue mechanics constantly
- manual flush should remain available, but secondary

## Truth Vocabulary

The product must preserve the existing runtime truth split.

### Queued Locally

`Queued locally` means:

- the scan has been accepted into the local queue
- it is durable on-device
- it is waiting for or undergoing upload

It does not mean:

- server confirmed
- attendee admitted
- queue backlog cleared

### Upload State

`Upload state` means transient orchestration truth from the coordinator, such
as:

- uploading
- retry pending
- auth expired
- idle

### Server Result

`Server result` means persisted backend-classified outcome truth after upload
attempts and classification.

This is the only place where the product may talk about confirmed server
outcomes.

## Surface Policy

### Scan Surface

The `Scan` destination should show only what scanning needs.

It may show:

- local capture feedback
- compact queue/upload warnings
- auth-expired or stale-sync warnings when they block or degrade scanning

It should not make these primary:

- manual flush buttons
- diagnostics dumps
- detailed sync history

### Event Surface

The `Event` destination is the correct place for broader operational visibility.

It may show:

- sync freshness
- queue depth
- upload state
- latest flush summary
- recent server-result summary
- intervention-needed states

It should still behave like an operator runtime surface, not a backend admin
screen.

### Overflow / Support

Overflow is the correct home for:

- manual flush fallback/debug actions
- diagnostics/support entry points
- permission recovery/support
- logout

This keeps debug and recovery tools available without turning them into the
main workflow.

## Sync Policy

### Preferred Behavior

Attendee sync should become a mostly automatic system behavior once the product
shell exists.

The preferred operator experience is:

- login succeeds
- the app ensures attendee data is ready or clearly warns when it is stale or
  missing
- the operator starts scanning

### Manual Sync

Manual sync remains useful, but secondary.

Policy for later implementation:

- manual sync is available from `Event`
- manual sync is not a dominant `Scan` control
- sync status is visible before manual sync is needed

### Sync Warning Threshold

Sync should become visually important only when one of these is true:

- no attendee cache exists yet
- sync is stale enough to materially affect operator confidence
- sync failed and operator action is required

Outside those cases, sync should be background status, not foreground workflow.

## Flush Policy

### Preferred Behavior

Auto-flush remains the normal behavior.

The operator expectation should be:

- scans queue locally
- uploads happen automatically when runtime conditions allow
- warnings appear only when backlog, auth, or connectivity issues matter

### Manual Flush

Manual flush remains:

- fallback
- debug
- support/admin affordance

Manual flush should not dominate the `Scan` experience and should not become a
primary operator CTA.

### When Flush State Becomes Prominent

Flush state should become prominent when:

- backlog is growing
- auth has expired
- retryable failures are leaving unresolved queue depth
- operator confidence in later upload is at risk

Otherwise, upload state should remain compact background information.

## Auth Expiry And Backlog Policy

Auth expiry is an intervention state, not normal scanning status noise.

When auth expires:

- queued scans remain preserved locally
- auto-flush cannot complete
- product must clearly signal that re-login is required

When backlog exists but auth is still valid:

- auto-flush remains preferred
- `Event` should make the backlog understandable
- `Scan` should warn only as much as needed to preserve operator confidence

## Offline Policy

When offline:

- local queueing still works
- server confirmation does not exist yet
- auto-flush should resume when conditions allow
- UI must not imply that offline capture equals completed admission

If offline and no attendee cache exists, that is a higher-severity operator
state than ordinary retry backlog.

## Rejected Product Shapes

This policy rejects:

- making manual flush the primary action on `Scan`
- making diagnostics a first-class operator workflow
- forcing operators to understand queue plumbing during normal use
- describing queued-local captures as confirmed server acceptance

## Handoff

This policy should guide later phases as follows:

1. Phase 9: shell scaffold decides where status and overflow controls live
2. Phase 10: `Scan` shows only compact scan-critical sync/flush state
3. Phase 12: `Event` becomes the main operational visibility surface for sync,
   queue depth, and upload state
