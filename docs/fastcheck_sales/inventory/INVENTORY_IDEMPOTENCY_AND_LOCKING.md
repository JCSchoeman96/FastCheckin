# Inventory Idempotency and Locking

## Required Idempotency Keys

| Operation | Key shape |
|---|---|
| reserve | `sales_order_id` or public_reference + checkout_session_id + action + attempt/version |
| consume | `sales_order_id` + payment_attempt_id/provider_reference + action |
| release | checkout_session_id or public_reference + release reason + action |
| expire | hold_key + expiry timestamp + action |
| reconcile | offer_id + reconciliation run id |

## Locking Rules

- Use short Redis locks for per-order operations.
- Do not use one global inventory lock for all offers.
- Do not hold locks while performing external HTTP.
- Do not hold locks while performing slow Postgres queries.
- Lua/atomic scripts must perform only bounded Redis work.
- Postgres optimistic locking still applies to durable order/checkout
  transitions.

## Duplicate Execution Rules

- Duplicate reserve must not double-decrement availability.
- Duplicate consume must not double-consume or double-issue tickets.
- Duplicate release must not double-increment availability.
- Duplicate expiry must not double-release.
- Duplicate reconciliation must not corrupt active state.
