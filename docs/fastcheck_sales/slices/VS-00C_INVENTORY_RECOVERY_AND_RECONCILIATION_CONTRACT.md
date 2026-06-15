# VS-00C Inventory Recovery and Reconciliation Contract

## Purpose

Define Redis/Postgres inventory recovery, reconciliation, reservation, consume,
release, expiry, cache, and failure contracts before Redis Lua, checkout,
payment, or ticket issuance implementation begins.

## Scope

In scope:

- Inventory authority model.
- Redis keys and data structures.
- `ReservationLedger` operation contracts.
- Idempotency and locking rules.
- Hold TTL and expiry policy.
- Redis failure and recovery policy.
- Redis/Postgres reconciliation policy.
- Inventory cache/PubSub rules.
- Inventory health and launch gates.

Out of scope:

- Elixir implementation.
- Redis Lua scripts.
- Ash resources.
- Migrations.
- Checkout implementation.
- Paystack implementation.
- Meta/WhatsApp implementation.
- Ticket issuance.
- Oban workers.
- Admin UI.
- Tests.
- Scanner changes.

## Documents

- [Inventory Master Contract](../inventory/INVENTORY_MASTER_CONTRACT.md)
- [Inventory Authority Model](../inventory/INVENTORY_AUTHORITY_MODEL.md)
- [Redis Key Structure](../inventory/REDIS_KEY_STRUCTURE.md)
- [ReservationLedger Operation Contract](../inventory/RESERVATION_LEDGER_OPERATION_CONTRACT.md)
- [Inventory Idempotency and Locking](../inventory/INVENTORY_IDEMPOTENCY_AND_LOCKING.md)
- [Hold TTL and Expiry Policy](../inventory/HOLD_TTL_AND_EXPIRY_POLICY.md)
- [Redis Failure and Recovery Policy](../inventory/REDIS_FAILURE_AND_RECOVERY_POLICY.md)
- [Redis Postgres Reconciliation Policy](../inventory/REDIS_POSTGRES_RECONCILIATION_POLICY.md)
- [Inventory Cache and PubSub Policy](../inventory/INVENTORY_CACHE_AND_PUBSUB_POLICY.md)
- [Inventory Health and Launch Gates](../inventory/INVENTORY_HEALTH_AND_LAUNCH_GATES.md)
- [Inventory Test Plan](../inventory/INVENTORY_TEST_PLAN.md)

## Completion Checklist

- [x] Define Redis hot inventory and Postgres/Ash durable authority split.
- [x] Define Redis keys and data structures.
- [x] Define `ReservationLedger` operation contracts.
- [x] Define idempotency, locking, hold TTL, expiry, failure, restart recovery,
  reconciliation, cache, PubSub, and launch health gates.
- [x] Require no checkout while inventory health is unknown or unhealthy.
- [x] Require late verified payments after hold expiry to re-reserve/consume or
  move to manual review.

## RED Documentation Checks

VS-00C is not accepted if:

- Inventory authority between Redis and Postgres/Ash is unclear.
- Any channel can bypass `ReservationLedger`.
- Redis key structure is missing.
- Reserve/consume/release/expire behavior is undefined.
- Idempotency and duplicate execution behavior is undefined.
- Redis unavailable behavior allows new reservations.
- Redis restart recovery can reopen sales without reconciliation.
- Late payment after hold expiry can blindly issue tickets.

## GREEN Documentation Checks

VS-00C is accepted when:

- Redis owns hot operational inventory during active sales.
- Postgres/Ash owns durable sales intent and recovery facts.
- `ReservationLedger` is the only allowed inventory mutation boundary.
- Required Redis keys, data structures, operations, and result shape are defined.
- Failure/recovery and reconciliation behavior are explicit.
- Inventory health gates block unsafe sale opening.
- No runtime code is added.

## Acceptance Criteria

- Inventory contract docs exist in allowed docs paths.
- Every channel is forbidden from bypassing `ReservationLedger`.
- Late payment, Redis failure, restart recovery, and reconciliation rules are
  explicit.
- Future implementation tests are documented.
