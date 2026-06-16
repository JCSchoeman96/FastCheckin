# VS-01G Index and Migration Verification

## Status

Implemented as a verification-only Sales foundation slice.

## Scope

VS-01G verifies the database contract created by VS-01B through VS-01E and
protected by VS-01F. It does not add runtime behavior, resources, workflows,
provider integrations, Redis behavior, workers, routes, UI, scanner changes, or
Android/mobile changes.

## Prior Contracts Reviewed

- VS-00A state-machine and failure-policy finalization.
- VS-00B security, PII, token, raw payload, and event access policy.
- VS-00C inventory recovery and reconciliation contract.
- VS-00D WhatsApp-first launch scope, `event_scoped_first`, and deferred
  `organization_id`.
- VS-01B through VS-01F implementation handoffs.

PR #340 is merged, so the VS-01F handoff gate is satisfied.

## Tables Verified

- `sales_ticket_offers`
- `sales_orders`
- `sales_order_lines`
- `sales_checkout_sessions`
- `sales_payment_attempts`
- `sales_payment_events`
- `sales_ticket_issues`
- `sales_delivery_attempts`
- `sales_conversations`
- `sales_state_transitions`

The first-release owner/access boundary remains `event_id`. `organization_id`
is intentionally deferred and must not be present on current Sales tables or
resources.

## Index and Constraint Coverage

The VS-01G test verifies required query-path indexes by PostgreSQL catalog
facts: index name, ordered columns, uniqueness, and partial predicate where
applicable.

Critical partial unique indexes are verified with precise nullable semantics:

- `sales_ticket_offers(event_id, name)` where `archived_at IS NULL`.
- `sales_orders(idempotency_key)` where `idempotency_key IS NOT NULL`.
- `sales_checkout_sessions(redis_hold_key)` where `redis_hold_key IS NOT NULL`.
- `sales_payment_events(provider, provider_event_id)` where
  `provider_event_id IS NOT NULL`.
- `sales_payment_events(provider, payload_hash)` where
  `provider_event_id IS NULL`.
- `sales_ticket_issues(ticket_code)` where `ticket_code IS NOT NULL`.
- `sales_ticket_issues(attendee_id)` where `attendee_id IS NOT NULL`.

Direct duplicate insert tests verify DB-level enforcement for public order
references, idempotency keys, order line numbers, checkout session uniqueness,
Redis hold keys, payment provider references, payment event dedupe identities,
ticket code uniqueness when present, ticket line-item sequence uniqueness, and
attendee link uniqueness when present.

## Relationship Integrity

Foreign keys are verified for:

- `sales_order_lines.sales_order_id -> sales_orders.id`
- `sales_order_lines.ticket_offer_id -> sales_ticket_offers.id`
- `sales_checkout_sessions.sales_order_id -> sales_orders.id`
- `sales_payment_attempts.sales_order_id -> sales_orders.id`
- `sales_ticket_issues.sales_order_id -> sales_orders.id`
- `sales_ticket_issues.sales_order_line_id -> sales_order_lines.id`
- `sales_delivery_attempts.sales_order_id -> sales_orders.id`
- `sales_delivery_attempts.ticket_issue_id -> sales_ticket_issues.id`
- `sales_orders.sales_conversation_id -> sales_conversations.id`

Accepted non-FK relationships:

- `sales_orders.whatsapp_conversation_id` remains legacy/reference-shaped
  string data.
- `sales_payment_events.provider_reference` links to attempts by provider
  reference, not FK.
- `sales_ticket_issues.attendee_id` is a nullable external reference to legacy
  attendees with a partial unique index, not an Attendee FK.
- `sales_state_transitions.entity_type/entity_id` is polymorphic audit data and
  intentionally has no FK.

## Ash Identity Alignment

The VS-01G test verifies critical Ash identities and AshPostgres
`identity_index_names` align with the DB unique indexes for:

- `TicketOffer.unique_active_name_per_event`
- `Order.unique_public_reference`
- `Order.unique_idempotency_key`
- `OrderLine.unique_line_number_per_order`
- `CheckoutSession.unique_order`
- `CheckoutSession.unique_redis_hold_key`
- `PaymentAttempt.unique_provider_reference`
- `PaymentEvent.unique_provider_event_id`
- `PaymentEvent.unique_provider_payload_hash`
- `TicketIssue.unique_ticket_code`
- `TicketIssue.unique_line_item_sequence`
- `TicketIssue.unique_attendee_id`

## Migration Review

Default migration strategy for VS-01G is no rewrite of existing migrations.
Existing Sales migrations use reversible `change/0` operations for table
creation, column additions, named indexes, unique indexes, foreign keys, and
constraints.

If a future RED test proves a missing DB fact, add a new corrective migration.
Do not modify old migration files unless a maintainer explicitly confirms those
migrations have not been shared or applied outside local development.

## Performance and Scaling Posture

Hot data remains Redis-owned in future inventory slices; VS-01G does not add or
mutate Redis data.

Warm offer display cache remains future Cachex/Redis work; VS-01G only verifies
the durable Postgres fallback indexes.

Cold durable Sales truth remains Postgres/Ash. Verified indexes support future
admin, worker, support, expiry, payment retry, webhook dedupe, ticket issuance
idempotency, delivery retry, scanner-visibility, conversation handoff, and
audit-timeline query paths.

No PubSub events, cache invalidation, Oban jobs, ETS/Cachex behavior, or runtime
database calls are added by this slice.

## Security and Privacy

No secrets are committed.

No raw provider payloads are logged or broadly indexed. Lookup and dedupe paths
use provider references, provider event IDs, payload hashes, status fields, and
processing status indexes.

No customer-facing plaintext tokens are introduced. Existing token-shaped Sales
fields remain hashes or sensitive fields according to prior resource policy.

Tests use synthetic data only. No real customer PII is required.

Admin/operator access remains governed by the VS-01F Ash policy foundation. This
slice does not broaden policies or add customer/session access.

## Boundaries Preserved

VS-01G does not add:

- new Sales resources,
- workflow actions,
- generic `update_status` or `update_state`,
- checkout behavior,
- Redis inventory or Lua scripts,
- Paystack behavior,
- WhatsApp/Meta behavior,
- ticket issuance,
- QR/token generation,
- Oban workers,
- routes/controllers/LiveViews/UI,
- scanner, attendee, event, mobile, or Android changes,
- `organization_id`,
- dependency upgrades.

## Verification

Primary new test:

- `test/fastcheck/sales/vs_01g_index_and_migration_verification_test.exs`

Required verification commands:

- `mix test test/fastcheck/sales/vs_01g_index_and_migration_verification_test.exs`
- `mix test test/fastcheck/sales/`
- `mix test`
- `mix precommit`
