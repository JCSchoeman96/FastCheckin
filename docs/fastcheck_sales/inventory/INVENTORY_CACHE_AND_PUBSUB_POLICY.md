# Inventory Cache and PubSub Policy

## Cache Rules

- Redis hot inventory remains checkout authority.
- Warm display cache may be used for event offer lists and admin dashboards.
- Display cache must include health/degraded markers when available.
- Cache misses must not trigger unbounded Postgres scans during checkout
  traffic.
- Cache invalidation follows offer initialization, reserve, consume, release,
  expire, reconcile, and health changes.

## PubSub Rules

- Availability changes should publish event/offer updates for LiveView/admin
  surfaces.
- PubSub messages should include event id, offer id, availability snapshot,
  health state, and correlation id.
- PubSub is not the source of truth.
- Missed PubSub updates must be recoverable from Redis hot state and durable
  reconciliation.

Recommended topic families:

- `sales:event:{event_id}:offers`
- `sales:offer:{offer_id}:availability`

Recommended event names:

- `offer_availability_changed`
- `inventory_ledger_degraded`
- `inventory_reconciled`
- `hold_expired`

Payload rules:

- Include identifiers, quantities, health state, and correlation id only.
- Do not publish PII, provider payloads, or tokens.

## Forbidden

- Polling loops over large tables during active sales.
- Cache-only checkout decisions.
- PubSub-only inventory state.
