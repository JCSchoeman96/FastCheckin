# ReservationLedger Operation Contract

## Boundary

Future module:

```text
FastCheck.Sales.Inventory.ReservationLedger
```

All inventory mutation must go through this boundary.

Result envelope contract:

- `{:ok, result_map}`
- `{:error, error_code, metadata_map}`

Forbidden operations:

- direct Redis mutation from controllers;
- direct Redis mutation from LiveViews;
- direct Redis mutation from WhatsApp handlers;
- direct Redis mutation from Ash resources;
- direct increment/decrement outside `ReservationLedger`;
- manual Redis CLI fixes during live sale without runbook and audit.

## `reserve/5`

```text
reserve(offer_id, order_public_reference, quantity, ttl_seconds, idempotency_key)
```

Preconditions:

- Inventory health is healthy.
- Offer is sales-enabled and within sales window.
- Quantity is positive and within policy.
- Order public reference and idempotency key are present.

Outcomes:

| Case | Outcome |
|---|---|
| Enough inventory | Hold created, availability decremented, expiry recorded. |
| Insufficient inventory | No mutation; return `insufficient_inventory`. |
| Duplicate same idempotency | Return existing hold/idempotent success. |
| Duplicate different quantity | Return conflict/manual-review-required. |
| Redis unhealthy | Reject with `inventory_unavailable`. |

Required success fields:

- `offer_id`
- `order_public_reference`
- `quantity`
- `available_after`
- `hold_key`
- `expires_at`
- `revision`

## `consume/4`

```text
consume(offer_id, order_public_reference, quantity, idempotency_key)
```

Preconditions:

- Payment verification succeeded.
- Hold exists or payment-after-expiry recovery has re-reserved inventory.
- Hold belongs to order.
- Quantity matches order lines.

Rules:

- Do not decrement availability again if reserve already decremented it.
- Mark hold consumed/sold.
- Remove or mark zset hold so expiry cannot release it.
- Reject missing/expired hold unless recovery policy applies.
- If hold is expired/released, consume only through approved payment-after-expiry
  re-reserve policy.

## `release/3`

```text
release(offer_id, order_public_reference, idempotency_key)
```

Rules:

- Increment availability exactly once.
- Do not release consumed holds.
- Mark hold released or remove consistently.
- Remove/reconcile zset entry.

## `expire_due_holds/1`

```text
expire_due_holds(now)
```

Rules:

- Process due holds in bounded batches.
- Release only still-active/unconsumed holds.
- Skip consumed holds.
- Remove stale zset members.
- Retry safely after Redis errors.

## `get_availability/1`

```text
get_availability(offer_id)
```

Rules:

- Read Redis hot state during active sale.
- Return health/degraded status with availability.
- Do not scan Postgres during checkout traffic.

## `mark_offer_health/3`

```text
mark_offer_health(offer_id, health_state, reason)
```

Allowed health states:

- `healthy`
- `rebuilding`
- `degraded`
- `closed`

Also expose explicit convenience operations:

```text
mark_offer_degraded(offer_id, reason)
mark_offer_healthy(offer_id)
```

## `reconcile_offer/1`

```text
reconcile_offer(offer_id)
```

Rules:

- Safe to run repeatedly.
- Mark inventory rebuilding/degraded during reconciliation.
- Prefer durable issued-ticket/order facts over Redis counters.
- Produce reconciliation report.
- Do not reopen sale while inconsistent.

## Required error families

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
