# Inventory Master Contract

## VS-04A Authority

This document is the normative entry point and precedence contract for Sales
inventory behavior in VS-04A.

- If inventory documents disagree, this file wins.
- Other documents under `docs/fastcheck_sales/inventory/*.md` provide detail
  and must not contradict this contract.
- Conflicts must be resolved by updating this file and aligning the detail docs.

## Principle

Redis owns hot operational inventory during active sales. Postgres/Ash owns
durable sales intent, orders, checkout sessions, payments, issued-ticket audit,
and recovery source data.

## Required Boundaries

- `FastCheck.Sales.Inventory.ReservationLedger` is the only allowed mutation
  boundary for inventory keys.
- Ash resources, controllers, LiveViews, workers, and WhatsApp handlers must
  not mutate inventory keys directly.
- Ash resources must not perform Redis Lua/script logic.
- Webhooks are never ticket-issuance authority and must not bypass inventory
  mutation rules.

## Channels Covered

This policy applies to:

- WhatsApp sales.
- Admin-assisted sales.
- Internal pilot sales.
- Future web checkout sales.

## Non-Negotiable Rules

- No checkout may bypass `ReservationLedger`.
- No WhatsApp flow may bypass `ReservationLedger`.
- No admin-assisted sale may bypass `ReservationLedger` unless a documented
  manual override exists and is audited.
- No future web checkout may bypass `ReservationLedger`.
- No ticket may be issued merely because Postgres says an order exists.
- No ticket may be issued after hold expiry unless payment-after-expiry recovery
  re-reserves inventory or moves the order to manual review.
- No Redis-unhealthy sale may continue accepting reservations.
- Unknown inventory health is unsafe and must fail closed.

## Canonical Redis Key Families

- `sales:offer:{offer_id}:inventory` (hash)
- `sales:offer:{offer_id}:holds` (sorted set)
- `sales:hold:{public_reference}` (hash)
- `sales:order:{public_reference}:lock` (short-lived lock key)
- `sales:inventory:dedupe:{operation}:{idempotency_key}` (TTL dedupe key)
- `sales:inventory:events:{offer_id}` (bounded event trail)
- `sales:event:{event_id}:offers` (warm event-offer cache key family)

## Canonical ReservationLedger Operations

- `reserve(offer_id, order_public_reference, quantity, ttl_seconds, idempotency_key)`
- `consume(offer_id, order_public_reference, quantity, idempotency_key)`
- `release(offer_id, order_public_reference, idempotency_key)`
- `expire_due_holds(now)`
- `get_availability(offer_id)`
- `reconcile_offer(offer_id)`
- `mark_offer_degraded(offer_id, reason)`
- `mark_offer_healthy(offer_id)`

## Result Envelope and Error Contract

Mutating operations return tagged results:

- `{:ok, result_map}`
- `{:error, error_code, metadata_map}`

Required error families:

- `:offer_not_found`
- `:offer_not_active`
- `:invalid_quantity`
- `:insufficient_inventory`
- `:already_reserved`
- `:already_consumed`
- `:already_released`
- `:hold_expired`
- `:hold_not_found`
- `:ledger_unavailable`
- `:ledger_degraded`
- `:lock_timeout`
- `:reconciliation_required`
- `:invalid_idempotency_key`
- `:unexpected_redis_response`

## Standard Operation Result Shape

Future operations should return structured results containing:

- `status`
- `offer_id`
- `order_public_reference`
- `quantity`
- `available_after`
- `hold_key`
- `expires_at`
- `idempotency_key`
- `reason`
- `correlation_id`

Result categories:

- `:ok` with structured data.
- `:error` with machine-readable reason.
- idempotent success for duplicate safe retries.
- manual-review-required result where human intervention is needed.

## VS-04B and VS-04C Implementation Gate

VS-04A is complete only when downstream implementation slices can build without
re-deciding keys, operation signatures, idempotency behavior, locking semantics,
TTL/expiry policy, degraded fail-closed behavior, restart/recovery rules,
reconciliation precedence, and cache/PubSub invalidation rules.
