# Runtime Architecture

## Purpose

This document defines the target runtime shape for the FastCheck Android
scanner app before implementation begins. It replaces the current temporary
control-panel shell with a product runtime organized around login, an
authenticated shell, and operator-first navigation.

This is a planning document only. It does not change Kotlin, XML, backend
contracts, or design-system APIs.

## Current Repo Grounding

The live Android runtime is still centered on one activity and one mixed XML
screen:

- `app/MainActivity.kt` owns login, sync, scanner permission and preview,
  manual queue controls, diagnostics refresh, and autoflush triggers.
- `activity_main.xml` mixes login, attendee sync, scanner preview, manual queue
  controls, and diagnostics in one vertical control panel.

The current runtime contract remains intentionally narrow:

- `POST /api/v1/mobile/login`
- `GET /api/v1/mobile/attendees`
- `POST /api/v1/mobile/scans`

The current shell is therefore a temporary operator/admin surface, not the
target product runtime.

## Target Runtime Layers

The target runtime has 2 layers.

### 1. Unauthenticated Login And Bootstrap Gate

The login/bootstrap gate exists to do exactly this:

- collect `event_id` and `credential`
- submit login through `SessionRepository`
- surface immediate login failure states
- establish the authenticated event-scoped session
- decide whether the operator can enter the authenticated shell

The login/bootstrap gate does not own:

- camera lifecycle
- attendee search
- event health reporting
- diagnostics workflows
- manual queue/flush operations

### 2. Authenticated Shell

The authenticated shell is the long-term operator runtime once login succeeds.

Its responsibilities are:

- host bottom navigation
- host shell-level session and warning state
- route operators between major workflows
- own overflow/support entry points
- keep the product structure stable while features migrate off the temporary
  control panel

The authenticated shell does not implement queueing, sync, or scanner business
rules directly. It projects repository, Room, and coordinator truth through
tab-level view models.

## Bottom Navigation Structure

The authenticated shell uses 3 bottom-nav destinations.

### Scan

`Scan` is the primary operator workflow.

Its responsibilities are:

- scanner-ready operator surface
- camera permission and source readiness UI
- camera preview ownership
- local capture feedback such as queued locally, cooldown, blocked, and warning
  states
- compact visibility of sync/queue state when relevant to scanning

`Scan` is the only destination allowed to own camera lifecycle.

### Search

`Search` is the secondary operator workflow.

Its responsibilities are:

- attendee lookup
- attendee detail display
- manual check-in workflow later, using the existing queue-and-flush `IN` path
  rather than a separate admission API

`Search` is explicitly subordinate to `Scan`. It exists for fallback and manual
operator workflows, not as the first-run product surface.

### Event

`Event` is the tertiary operator workflow.

Its responsibilities are:

- current event summary
- attendee sync freshness
- queue depth and upload health
- last flush and persisted server-result summaries
- operational visibility without turning the screen into a diagnostics dump

`Event` is where broader runtime health belongs. It is not where camera control
or manual scan plumbing should dominate the UI.

## Overflow Responsibilities

Overflow is for lower-priority support/admin actions only:

- operator preferences and settings
- permission recovery affordances
- support/debug entry points
- manual flush fallback/debug actions
- logout

Overflow must not become a second event screen or a hidden primary workflow.
Its purpose is to keep support/admin actions out of the main bottom-nav
hierarchy.

## Ownership Boundaries

### Login Gate Ownership

The login gate owns:

- login form state
- submit/progress/error state
- successful session bootstrap

It does not own authenticated product navigation.

### Authenticated Shell Ownership

The shell owns:

- active destination selection
- shell-level warning placement
- overflow access
- destination handoff

It does not own scanner pipeline internals, queue persistence, or backend
contract logic.

### Scan Ownership

The `Scan` destination owns:

- scanner source activation while selected
- camera preview visibility
- scanner permission recovery affordances
- capture-feedback projection

It does not own sync orchestration logic or manual debug tooling as primary UI.

### Search Ownership

The `Search` destination owns:

- attendee lookup and list/detail projection
- manual search-oriented operator flows

It does not own camera lifecycle.

### Event Ownership

The `Event` destination owns:

- event-level status projection
- sync freshness visibility
- queue and flush visibility
- operator warnings that are broader than the immediate scan interaction

It does not own primary scanning interactions.

## Lifecycle Policy

The target runtime keeps lifecycle ownership explicit.

- The login/bootstrap gate is not scanner-active.
- The authenticated shell can remain alive while switching destinations.
- `Scan` owns scanner/camera lifecycle.
- `Search` and `Event` never own scanner/camera lifecycle.
- Backgrounded app state must not keep camera scanning active.

This keeps product structure aligned with the existing scanner source
abstractions without leaving camera lifecycle attached to the activity shell
itself.

## `MainActivity` Responsibility Split

Today, `MainActivity` directly coordinates:

- login button wiring
- sync button wiring
- camera permission launcher
- scanner source binding
- queue and flush buttons
- diagnostics refresh
- cross-view-model observation
- autoflush trigger dispatch

That is temporary.

The future role of `MainActivity` should shrink toward:

- Android entry point
- shell host
- lifecycle bridge for the active runtime surface

`MainActivity` should stop being the place where all operator workflows are
declared and coordinated directly. The problem to solve in later phases is
shell shape, not more control-panel refinement.

## Explicit Rejections

This architecture rejects:

- keeping the all-in-one XML control panel as the long-term product
- inventing backend routes beyond `/api/v1/mobile/*`
- making diagnostics a primary operator destination
- making manual flush a primary scan-screen CTA
- treating smartphone and hardware-scanner UX as equal first priorities in this
  phase

## Handoff To Implementation Phases

This architecture is intended to hand off into the already locked sequence:

1. Phase 9: login/bootstrap gate plus authenticated shell scaffold
2. Phase 10: first real smartphone-first `Scan` runtime
3. Phase 11: `Search` data/model/projection work plus Search UI
4. Phase 12: `Event` operational surface plus relocation of support/debug
   controls

The next implementation phase should introduce shell structure first. It should
not try to build `Search` and `Event` leaf screens before the product shell
exists.
