# Inventory Idempotency and Locking

## Required Idempotency Keys

| Operation | Key shape |
|---|---|
| reserve | `order_public_reference + reserve + idempotency_key` |
| consume | `order_public_reference + consume + idempotency_key` |
| release | `order_public_reference + release + idempotency_key` |
| expire | hold_key + expiry timestamp + action |
| reconcile | offer_id + reconciliation run id |

## Locking Rules

- Use short Redis locks for per-order operations.
- Use `sales:order:{public_reference}:lock` with bounded TTL only.
- Do not use one global inventory lock for all offers.
- Do not hold locks while performing external HTTP.
- Do not hold locks while performing slow Postgres queries.
- Lua/atomic scripts must perform only bounded Redis work.
- Postgres optimistic locking still applies to durable order/checkout
  transitions.
- Lock timeout must return explicit `:lock_timeout` error; do not retry forever.

## Duplicate Execution Rules

- Duplicate reserve must not double-decrement availability.
- Duplicate consume must not double-consume or double-issue tickets.
- Duplicate release must not double-increment availability.
- Duplicate expiry must not double-release.
- Duplicate reconciliation must not corrupt active state.

## Dedupe Key Retention

- Persist dedupe operation results in
  `sales:inventory:dedupe:{operation}:{idempotency_key}`.
- TTL must exceed realistic retry windows.
- Consume/payment-related dedupe TTL minimum: 24 hours.
