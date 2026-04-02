# Runtime Adoption Strategy

## Purpose

This document defines how the repo should move from the current one-screen
control panel toward the structured scanner product runtime.

The goal is to choose the implementation path before code starts so later
phases do not re-debate shell shape.

This is a planning document only.

## Current Repo Reality

The current Android runtime is in an in-between state:

- `MainActivity` is heavy and directly coordinates nearly every workflow
- `activity_main.xml` is a mixed control panel
- Compose already exists in the repo as design-system foundation and previews
- the active runtime contract is still only `/api/v1/mobile/*`

The core product problem is therefore shell shape, not lack of leaf screens.

## Options

### Option 1: All-XML-First Restructuring

Description:

- keep the runtime primarily in XML/ViewBinding
- split the control panel into more XML/fragment screens first
- postpone Compose until much later

Pros:

- reuses current shell technology
- may feel lower-risk in the very short term

Cons:

- keeps investing in the wrong long-term shell
- turns shell migration into later duplicate work
- leaves the heavy activity/runtime structure alive longer
- underuses the Compose design-system foundation already present in the repo

Decision:

- rejected

### Option 2: Leaf-Screens-First

Description:

- keep the current shell alive
- start by building isolated `Scan`, `Search`, or `Event` leaf screens first
- postpone shell replacement until later

Pros:

- may appear to show progress quickly on individual screens

Cons:

- solves the wrong problem first
- leaves the control-panel shell alive longer
- forces new screens to fit under the wrong host structure
- risks duplicating navigation and shell work later

Decision:

- rejected

### Option 3: Authenticated-Shell-First

Description:

- keep login/bootstrap and shell-hosting concerns narrow
- introduce the structured authenticated shell first
- use Compose first where it is strongest: the new shell layer and destination
  scaffolding
- migrate feature surfaces behind that shell in later phases

Pros:

- addresses the actual architecture problem first
- stops investing in the control-panel shell as product UI
- leverages the Compose design-system foundation where it has the most value
- preserves repository, worker, Room, and backend boundaries while changing
  product structure

Cons:

- requires shell decisions up front
- delays some leaf-screen polish until the shell is present

Decision:

- recommended

## Recommendation

The repo should adopt the authenticated-shell-first path.

This is the strongest path because:

- the current problem is that the runtime has the wrong shell shape
- the activity and XML control panel are temporary scaffolding, not a product
  foundation
- Compose already exists where it is most useful for a new shell layer
- shell modernization can happen without touching repositories, workers, Room,
  or backend contracts first

## Compose Entry Point

Compose should enter at the authenticated shell first.

That means:

- do not keep investing in the current control-panel shell as the long-term
  runtime host
- do not start by adding isolated Compose leaf screens under the wrong shell
- use Compose first for authenticated shell structure and destination scaffolds

The login/bootstrap gate does not need to be the first Compose surface. It can
stay intentionally narrow while the authenticated shell becomes the first new
runtime layer to take advantage of the existing Compose foundation.

## Phase Sequence After Phase 8

### Phase 9: Login / Bootstrap Gate And Authenticated Shell Scaffold

Phase 9 should do the structural work only:

- introduce the 2-layer runtime shape
- narrow login/bootstrap responsibilities
- add authenticated shell scaffold
- establish bottom-nav and overflow structure
- keep feature migrations intentionally limited

Phase 9 should not attempt to finish the full scanner runtime.

### Phase 10: First Real Smartphone-First `Scan` Runtime

Phase 10 should focus on:

- the `Scan` destination as the primary operator surface
- scanner/camera lifecycle ownership by `Scan`
- smartphone-first interaction and battery policy
- honest capture, queue, and warning projection

### Phase 11: Search Data / Model / Projection Work Plus Search UI

Phase 11 should focus on:

- DAO/query additions for attendee lookup
- model/projection expansion beyond current `AttendeeRecord`
- Search UI and attendee detail workflows
- manual check-in through the existing queue-and-flush `IN` path

### Phase 12: Event Operational Surface

Phase 12 should focus on:

- sync freshness
- queue depth
- upload state
- persisted server-result summary
- moving support/debug visibility out of the temporary shell

### Later Cleanup

After those phases:

- retire remaining control-panel surfaces
- simplify `MainActivity`
- reconsider whether the login/bootstrap gate should also be modernized further

## Why Shell-First Is Lower Risk

Shell-first is lower risk than it first appears because it avoids a more costly
later rewrite.

It does not require:

- repository rewrites
- worker rewrites
- Room schema changes as part of the shell step
- backend contract changes

It only requires the repo to stop treating the temporary control panel as the
future product.

## Guardrails

Later implementation should preserve these guardrails:

- no new backend routes beyond `/api/v1/mobile/*`
- no second auth/token system
- no shell decisions that make manual flush a primary workflow
- no camera ownership outside `Scan`
- no leaf-screen work that assumes the shell can stay as-is indefinitely

## Final Decision

The adoption path is:

- reject `all-XML-first`
- reject `leaf-screens-first`
- recommend `authenticated-shell-first`

The first implementation step after Phase 8 is therefore:

1. Phase 9: login/bootstrap gate plus authenticated shell scaffold
2. Phase 10: smartphone-first `Scan` runtime

That sequence is the clearest way to fix the actual runtime architecture
problem before feature expansion continues.
