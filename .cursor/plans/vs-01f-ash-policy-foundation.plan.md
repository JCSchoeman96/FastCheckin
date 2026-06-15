# Slice Planning Report - VS-01F Ash Policy Foundation

Plan ID: VS-01F-ash-policy-foundation
Plan version: v1
Status: Approved after reviewer feedback
Scope: VS-01F Ash Policy Foundation
Authority: This file is the active implementation contract for VS-01F. The VS-01F feature pack is the upstream source. VS-01B through VS-01E handoffs define merged implementation reality.
Last updated: 2026-06-15

Revision log:
- v1 - initial VS-01F implementation plan based on VS-01E handoff and VS-01F feature pack, patched after reviewer feedback.

## Implementation Contract

Implement only the VS-01F Ash policy foundation:

- Add Ash policy authorizers/policies on the existing ten Sales resources.
- Add field policies for restricted fields where Ash supports it.
- Add VS-01F policy tests.
- Add VS-01F boundary tests.
- Add VS-01F slice documentation.
- Keep this canonical Cursor plan file.

Strictly forbidden:

- migrations
- new tables or columns
- `organization_id`
- checkout workflows
- Paystack
- Redis
- WhatsApp/Meta
- ticket issuance
- delivery sending
- Oban workers
- routes/controllers/LiveViews/UI
- scanner/attendee/event/mobile changes
- generic `update_status` / `update_state`
- broad `customer_session` reads
- broad admin/operator reads for resources without safe event scope
- admin/operator `bypass always()`

## Event Scope Rules

For resources with direct or relationship event scope:

- `TicketOffer`: scope by `event_id`.
- `Order`: scope by `event_id`.
- `OrderLine`: scope via `order.event_id`.
- `CheckoutSession`: scope via `order.event_id`.
- `PaymentAttempt`: scope via `order.event_id`.
- `TicketIssue`: scope via `order.event_id`.
- `DeliveryAttempt`: scope via `order.event_id`.

For resources without a reliable event scope path in VS-01F:

- `PaymentEvent`
- `StateTransition`
- `Conversation` rows not linked to an `Order`

Do not grant broad operator reads. Do not grant broad admin reads unless a global/system actor is explicitly used. Prefer system-only reads or deny until a later slice adds scoped actions/links.

## Test Contract

All policy reads must go through Ash with authorization enabled and an explicit actor.

Tests must distinguish:

- forbidden action/read: assert Ash forbidden error
- scoped read with no matching event: assert empty result
- restricted field: assert `Ash.ForbiddenField`

Do not rely on module existence or `Ash.Resource.Info` checks as policy proof.

## Optional Helper Constraint

Prefer inline policy checks first. If Ash policy syntax becomes duplicated or unclear, allow one small helper module:

- `lib/fastcheck/sales/policy_checks.ex`

Only include actor/event-scope checks. Do not add workflow, Repo calls, caching, HTTP, or business logic.
