# FastCheck Sales Feature Planning Pack — VS-04B Atomic Inventory Ledger Implementation

**Pack ID:** `0015_VS-04B_atomic-inventory-ledger-implementation`  
**Repository path:** `docs/fastcheck_sales/feature_packs/0015_VS-04B_atomic-inventory-ledger-implementation`  
**Slice:** `VS-04B`  
**Slice name:** Atomic Inventory Ledger Implementation  
**Version:** `v1.0`  
**Date:** 2026-06-12  
**Status:** Implementation planning pack — coding allowed only inside the approved Redis inventory boundary  
**Primary area:** Redis / Lua / Inventory / Concurrency / Tests  
**Depends on:** VS-00A, VS-00B, VS-00C, VS-00D, VS-01B, VS-01G, VS-03, VS-04A  
**Blocks:** VS-04C, VS-05, VS-14  
**Source docs:**

```text
docs/fastcheck_sales/SOURCE_DOCS/FastCheck_Sales_Ash_Atlas_Planning_Pack_v0.2.3_HARDENED.md
docs/fastcheck_sales/SOURCE_DOCS/FastCheck_Sales_Vertical_Slice_Roadmap_v1.1.3_HARDENED.md
```

---

## 1. Purpose

This pack instructs a coding agent to implement the **atomic Redis inventory ledger** for FastCheck Sales.

This is the first implementation slice for the hot inventory path. It must implement the approved `VS-04A` contract without inventing checkout behavior, Ash state transitions, payment behavior, or ticket issuance behavior.

Strategic framing remains:

```text
FastCheck Sales is multi-channel, but WhatsApp is first.

Primary production customer channel:
  WhatsApp via Meta Cloud API

Secondary supported Sales paths:
  admin-assisted sales
  web checkout sales
  internal pilot sales

Every sales channel must use the same Sales core and the same Redis inventory ledger.
```

The ledger must make overselling impossible under concurrent reservation attempts. Postgres/Ash owns durable business state; Redis owns hot reservation state.

---

## 2. Ultimate Outcome

After VS-04B is complete:

```text
FastCheck.Sales.Inventory.ReservationLedger exists.
FastCheck.Sales.Inventory.RedisScripts exists.
Redis scripts for reserve, consume, release, expire, and availability exist.
Reservations are atomic.
Consumption is atomic.
Release is atomic.
Expiry is safe and cannot release consumed holds.
Mutating operations are idempotent by idempotency key.
Availability never goes negative.
Concurrent reserve attempts cannot oversell.
Redis inventory keys do not contain customer PII.
Tests prove reserve/consume/release/expire behavior.
No Ash resource directly mutates Redis.
No checkout workflow is implemented yet.
No Paystack, WhatsApp, ticket issuance, or Attendee behavior is added.
```

The goal is not to build the checkout flow yet. The goal is to produce the reliable hot inventory primitive that checkout will call later.

---

## 3. Scope

### In scope

```text
Create or update FastCheck.Sales.Inventory.ReservationLedger.
Create or update FastCheck.Sales.Inventory.RedisScripts.
Implement Redis Lua/script-backed reserve operation.
Implement Redis Lua/script-backed consume operation.
Implement Redis Lua/script-backed release operation.
Implement Redis Lua/script-backed expire_due_holds operation.
Implement Redis-backed get_availability operation.
Implement initialization/sync helper for offer inventory if needed for tests.
Implement explicit return tuples/error codes.
Implement idempotency behavior for mutating operations.
Implement short-lived Redis lock behavior where the contract requires it.
Implement Redis test helpers/support fixtures.
Add RED/GREEN tests before implementation.
Add concurrency tests proving no oversell.
Add boundary tests proving Ash resources/controllers do not mutate inventory keys.
Add logging tests or code review checks to prevent PII/token logging.
```

### Out of scope

```text
No checkout session workflow.
No Order workflow.
No PaymentAttempt or Paystack behavior.
No webhook behavior.
No WhatsApp or Meta API behavior.
No ticket issuing.
No Attendee creation.
No scanner hot-path changes.
No LiveView/admin UI.
No full Redis/Postgres reconciliation tooling; that belongs to VS-04C.
No broad data migrations unless needed only for test support and explicitly approved.
No Ash resource actions that mutate Redis.
```

---

## 4. Required Pre-Implementation Decisions

The coding agent must read and follow the accepted outputs from:

```text
VS-00A State Machine and Failure Policy Finalization
VS-00B Security, PII, and Token Policy Finalization
VS-00C Inventory Recovery and Reconciliation Contract
VS-00D MVP Purchase Entry-Point and Launch Scope Decision
VS-03 Ticket Offer Management
VS-04A Inventory Ledger Contract Finalization
```

### Required discovery step

Before changing code, the agent must locate and document actual repository paths for:

```text
existing Redis connection module or pool
existing Redis dependency/library
existing Cachex configuration
existing Phoenix PubSub module
existing telemetry/logging conventions
existing test support helpers
existing async test limitations around Redis
existing TicketOffer resource/module path
existing Sales domain module path
```

If the repository already has a Redis wrapper, use it. Do not create a second Redis connection stack unless no approved wrapper exists.

---

## 5. Domain and Boundary Details

### Ash domain referenced, not modified

```text
FastCheck.Sales
```

### Ash resources referenced, not modified

```text
FastCheck.Sales.TicketOffer
FastCheck.Sales.CheckoutSession
FastCheck.Sales.Order
FastCheck.Sales.StateTransition
```

### Plain Elixir modules to implement

Preferred paths:

```text
lib/fastcheck/sales/inventory/reservation_ledger.ex
lib/fastcheck/sales/inventory/redis_scripts.ex
```

Optional test-support path:

```text
test/support/fastcheck/sales/inventory/redis_case.ex
```

Preferred test paths:

```text
test/fastcheck/sales/inventory/reservation_ledger_test.exs
test/fastcheck/sales/inventory/redis_scripts_test.exs
test/fastcheck/sales/inventory/reservation_ledger_concurrency_test.exs
```

### Forbidden paths for this slice

Do not modify these except for harmless compile fixes caused by the new modules:

```text
lib/fastcheck/sales/order.ex
lib/fastcheck/sales/checkout_session.ex
lib/fastcheck/sales/payment_attempt.ex
lib/fastcheck/sales/payment_event.ex
lib/fastcheck/sales/ticket_issue.ex
lib/fastcheck/tickets/issuer.ex
lib/fastcheck/payments/paystack/**
lib/fastcheck/messaging/whatsapp/**
lib/fastcheck_web/**
lib/fastcheck/attendees/**
lib/fastcheck/events/**
```

---

## 6. Redis Data Structures

The implementation must follow the accepted VS-04A contract. If the exact key names differ in the accepted contract, use the accepted contract and document the difference.

### `sales:offer:{offer_id}:inventory`

Recommended Redis type:

```text
hash
```

Required fields:

```text
offer_id
configured_quantity
available_quantity
reserved_quantity
consumed_quantity
revision
ledger_state
last_reconciled_at
updated_at
```

Rules:

```text
available_quantity >= 0
reserved_quantity >= 0
consumed_quantity >= 0
consumed_quantity <= configured_quantity unless explicit manual oversell policy exists
available_quantity + reserved_quantity + consumed_quantity should equal configured_quantity during healthy normal operation
```

### `sales:offer:{offer_id}:holds`

Recommended Redis type:

```text
zset
```

Member:

```text
order_public_reference
```

Score:

```text
unix expiry timestamp, preferably milliseconds if existing Redis wrapper supports it consistently
```

### `sales:hold:{public_reference}`

Recommended Redis type:

```text
hash
```

Required fields:

```text
offer_id
order_public_reference
quantity
status            # held | consumed | released | expired
idempotency_key
created_at
expires_at
consumed_at
released_at
expired_at
revision
```

Rules:

```text
This key must not store buyer name, phone, email, WhatsApp wa_id, Paystack reference, payment URL, ticket token, or QR token.
```

### `sales:order:{public_reference}:lock`

Recommended Redis type:

```text
short-lived SET NX PX key
```

Purpose:

```text
Prevent concurrent operations for the same order reference from racing consume/release/expire behavior.
```

### `sales:inventory:dedupe:{operation}:{idempotency_key}`

Recommended Redis type:

```text
string or hash with TTL
```

Purpose:

```text
Return prior result for duplicate mutating calls using the same idempotency key.
```

### `sales:inventory:events:{offer_id}`

Recommended Redis type:

```text
list or stream-like audit trail
```

Purpose:

```text
Operational debug/audit only.
Do not treat this as durable legal audit.
Do not put customer PII or secrets in this key.
```

---

## 7. Public API Contract

Implement the public API in `FastCheck.Sales.Inventory.ReservationLedger`.

### `initialize_offer/2` or equivalent

Purpose:

```text
Initialize Redis inventory state for an offer from durable configured inventory.
```

Recommended signature:

```text
initialize_offer(offer_id, configured_quantity)
```

Allowed return values:

```text
{:ok, availability_snapshot}
{:error, :invalid_quantity}
{:error, :redis_unavailable}
{:error, {:redis_error, reason}}
```

Rules:

```text
Must not reset an active ledger with existing holds/consumed counts unless an explicit force/reconcile option exists.
Force/reconcile behavior belongs to VS-04C unless the accepted VS-04A contract says otherwise.
```

### `reserve/5`

Recommended signature:

```text
reserve(offer_id, order_public_reference, quantity, ttl_seconds, idempotency_key)
```

Allowed return values:

```text
{:ok, hold_snapshot}
{:error, :invalid_quantity}
{:error, :invalid_ttl}
{:error, :offer_not_initialized}
{:error, :offer_unavailable}
{:error, :insufficient_inventory}
{:error, :duplicate_conflict}
{:error, :ledger_degraded}
{:error, :redis_unavailable}
{:error, {:redis_error, reason}}
```

Required behavior:

```text
Atomic.
Idempotent for the same idempotency key and same arguments.
Must fail safely if quantity exceeds available inventory.
Must not make available_quantity negative.
Must create hold hash and zset expiry entry together.
Must return existing successful result for duplicate same idempotency key.
Must return duplicate_conflict if same idempotency key is reused with conflicting arguments.
Must not create an Order or CheckoutSession.
```

### `consume/4`

Recommended signature:

```text
consume(offer_id, order_public_reference, quantity, idempotency_key)
```

Allowed return values:

```text
{:ok, consume_snapshot}
{:error, :hold_not_found}
{:error, :hold_expired}
{:error, :hold_released}
{:error, :quantity_mismatch}
{:error, :duplicate_conflict}
{:error, :ledger_degraded}
{:error, :redis_unavailable}
{:error, {:redis_error, reason}}
```

Required behavior:

```text
Atomic.
Idempotent.
Only held inventory can be consumed.
Consumed holds must not later be released by expiry.
reserved_quantity decreases.
consumed_quantity increases.
The hold status becomes consumed.
The hold is removed from the expiry zset or ignored by expire_due_holds.
Must not issue tickets or update Order status.
```

### `release/3`

Recommended signature:

```text
release(offer_id, order_public_reference, idempotency_key)
```

Allowed return values:

```text
{:ok, release_snapshot}
{:ok, :already_released}
{:ok, :already_expired}
{:error, :hold_not_found}
{:error, :hold_consumed}
{:error, :duplicate_conflict}
{:error, :ledger_degraded}
{:error, :redis_unavailable}
{:error, {:redis_error, reason}}
```

Required behavior:

```text
Atomic.
Idempotent.
Held inventory is returned to available_quantity.
Consumed inventory must never be released.
Released holds must be removed from the zset or ignored by expiry.
Must not update CheckoutSession or Order status.
```

### `expire_due_holds/1`

Recommended signature:

```text
expire_due_holds(now)
```

Allowed return values:

```text
{:ok, %{expired_count: count, skipped_count: count, errors: list}}
{:error, :redis_unavailable}
{:error, {:redis_error, reason}}
```

Required behavior:

```text
Find due holds from zsets.
Expire only holds still in held status.
Return held quantity to available_quantity.
Never release consumed holds.
Must be safe if run more than once.
Must be safe if delayed.
May process in bounded batches to avoid blocking Redis.
```

### `get_availability/1`

Recommended signature:

```text
get_availability(offer_id)
```

Allowed return values:

```text
{:ok, availability_snapshot}
{:error, :offer_not_initialized}
{:error, :ledger_degraded}
{:error, :redis_unavailable}
{:error, {:redis_error, reason}}
```

Required behavior:

```text
Read from Redis hot inventory state.
Must not scan Postgres.
Must not compute live availability from TicketOffer.configured_quantity_available.
```

---

## 8. Snapshot Shapes

Use plain maps or structs consistently. Keep shapes stable for VS-05 checkout to consume later.

### Availability snapshot

```elixir
%{
  offer_id: offer_id,
  configured_quantity: integer,
  available_quantity: integer,
  reserved_quantity: integer,
  consumed_quantity: integer,
  ledger_state: :healthy | :degraded,
  revision: integer,
  updated_at: DateTime.t() | integer
}
```

### Hold snapshot

```elixir
%{
  offer_id: offer_id,
  order_public_reference: String.t(),
  quantity: integer,
  status: :held | :consumed | :released | :expired,
  expires_at: DateTime.t() | integer,
  revision: integer
}
```

Rules:

```text
Do not expose Redis implementation details to checkout callers unless needed.
Do not include idempotency key in normal logs.
Do not include buyer/customer/provider data.
```

---

## 9. Script / Lua Requirements

Implement scripts in `FastCheck.Sales.Inventory.RedisScripts` or an equivalent repository-approved location.

Required script responsibilities:

```text
reserve script
consume script
release script
expire single hold or expire batch script
availability read helper may be Redis command-based if safe
```

Script rules:

```text
All inventory counter changes must happen atomically inside Redis.
Do not implement reserve as multiple non-atomic Redis calls.
Do not rely on application-side check-then-set for availability.
All scripts must validate expected hold status before changing counters.
All scripts must return structured codes that ReservationLedger maps into public return tuples.
Scripts must protect against negative counters.
Scripts must be safe under duplicate execution.
```

Script loading strategy:

```text
Use EVALSHA/script loading if the existing Redis wrapper supports it cleanly.
Fallback to EVAL is acceptable for MVP if it is wrapped and test-covered.
Do not scatter raw Lua calls across the codebase.
Only RedisScripts/ReservationLedger should know the Lua internals.
```

---

## 10. Idempotency Rules

### General rules

```text
Every mutating operation requires idempotency_key.
Same idempotency key + same operation + same arguments returns same logical result.
Same idempotency key + conflicting arguments returns duplicate_conflict.
Idempotency records should have bounded TTL.
Idempotency keys must not include raw customer PII.
```

### Operation-specific rules

```text
reserve:
  duplicate successful reserve returns the original hold snapshot.

consume:
  duplicate successful consume returns idempotent success and does not increment consumed twice.

release:
  duplicate successful release returns idempotent success and does not increment availability twice.

expire_due_holds:
  safe under duplicate or delayed execution; no explicit external idempotency key required if status checks are atomic.
```

---

## 11. Failure Behavior

### Redis unavailable

Required behavior:

```text
Return {:error, :redis_unavailable} or equivalent normalized error.
Do not fall back to Postgres as a live inventory counter.
Do not accept new reservations while Redis ledger health is unknown.
Do not silently assume inventory is available.
```

### Ledger degraded

Required behavior:

```text
If a ledger is marked degraded, reserve must fail closed.
get_availability may return degraded snapshot.
consume/release behavior must follow the accepted VS-04A policy.
Do not reopen sales automatically without reconciliation/health confirmation.
```

### Counter mismatch

Required behavior:

```text
If a script detects impossible counters, mark or return ledger_degraded.
Do not continue reservation.
Full repair belongs to VS-04C.
```

---

## 12. Cache, PubSub, and Telemetry

### Cache/PubSub

This slice may emit or provide hooks for:

```text
inventory reserved
inventory consumed
inventory released
inventory expired
availability changed
ledger degraded
```

But it must not build admin UI or checkout UI.

If PubSub is implemented now, use the existing app PubSub module and document event names. If PubSub integration would cause scope creep, expose a small internal callback/hook and leave actual UI subscription to later slices.

### Telemetry event names

Use or reserve these names:

```text
[:fastcheck, :sales, :inventory, :reserved]
[:fastcheck, :sales, :inventory, :consumed]
[:fastcheck, :sales, :inventory, :released]
[:fastcheck, :sales, :inventory, :expired]
[:fastcheck, :sales, :inventory, :reserve_failed]
[:fastcheck, :sales, :inventory, :ledger_degraded]
```

Rules:

```text
Telemetry metadata must not include PII, tokens, Paystack payloads, Meta payloads, or payment URLs.
Use offer_id and operation status only.
```

---

## 13. Performance and Scaling Review

### Data layer classification

```text
Hot data:
  active offer inventory
  active holds
  expiry zsets
  short-lived operation locks
  idempotency records

Warm data:
  event offer display cache
  active-offer lists

Cold data:
  TicketOffer durable configuration
  Order/CheckoutSession durable intent
  Payment/Ticket audit state
```

### Performance requirements

```text
reserve/consume/release must be single Redis-script-backed operations where possible.
No Postgres reads in reserve/consume/release hot path.
No large Redis key scans in request path.
expire_due_holds must operate in bounded batches.
get_availability must be O(1) for one offer.
```

### Flash-sale safety

```text
Reserve path must fail closed if Redis unavailable.
Reserve path must not use TicketOffer configured quantity as live counter.
Concurrent reserve attempts must not oversell.
Cache stampede protection must exist for offer display cache in later slices.
```

---

## 14. Security and PII Review

Forbidden in Redis inventory keys, values, events, logs, and telemetry:

```text
buyer_name
buyer_phone
buyer_email
phone_e164
wa_id
recipient
Paystack authorization_url
Paystack access_code
Paystack raw payloads
Meta raw payloads
ticket delivery token
QR token
plaintext idempotency secrets if generated from sensitive input
```

Allowed identifiers:

```text
offer_id
event_id if needed
order_public_reference if it is opaque and customer-safe
operation type
quantity
status
non-sensitive correlation_id
```

---

## 15. RED/GREEN Test Plan

The agent must write or update tests before implementation. Tests should fail in RED phase because the functions/scripts do not exist or do not yet satisfy behavior.

### RED tests must fail when

```text
ReservationLedger module is missing.
RedisScripts module is missing.
reserve/5 is missing.
consume/4 is missing.
release/3 is missing.
expire_due_holds/1 is missing.
get_availability/1 is missing.
reserve allows negative or zero quantity.
reserve allows invalid TTL.
reserve oversells under sequential calls.
reserve oversells under concurrent calls.
reserve creates non-atomic partial state.
consume increments consumed twice on duplicate call.
release increments availability twice on duplicate call.
expiry releases consumed holds.
expiry releases already released holds.
get_availability reads from Postgres/TicketOffer as live counter.
Redis unavailable falls back to Postgres and accepts reservation.
Redis keys/logs include PII or tokens.
Ash resources/controllers/LiveViews directly mutate inventory Redis keys.
```

### GREEN tests must prove

```text
initialize_offer creates healthy inventory state.
reserve/5 atomically decreases availability and creates hold state.
reserve/5 returns insufficient_inventory when quantity exceeds availability.
reserve/5 is idempotent for duplicate same key/args.
reserve/5 returns duplicate_conflict for same idempotency key with different args.
consume/4 atomically converts held inventory to consumed inventory.
consume/4 is idempotent and cannot consume twice.
release/3 returns held inventory to availability.
release/3 is idempotent and cannot release twice.
release/3 cannot release consumed holds.
expire_due_holds/1 expires only due held holds.
expire_due_holds/1 does not release consumed/released holds.
get_availability/1 returns Redis hot snapshot.
Concurrent reserve attempts never make availability negative.
Redis unavailable returns safe error and does not accept reservations.
No PII/tokens/provider payloads are logged or stored in inventory keys.
Only ReservationLedger/RedisScripts own Redis inventory mutation.
```

### Recommended test files

```text
test/fastcheck/sales/inventory/reservation_ledger_test.exs
test/fastcheck/sales/inventory/reservation_ledger_concurrency_test.exs
test/fastcheck/sales/inventory/redis_scripts_test.exs
test/fastcheck/sales/inventory/inventory_boundary_test.exs
```

### Concurrency test expectations

At minimum, test:

```text
configured quantity: 10
parallel reservation attempts: 25
reservation quantity each: 1
expected successful reservations: 10
expected failed reservations: 15
final available_quantity: 0
final reserved_quantity: 10
final consumed_quantity: 0
```

Also test mixed operations:

```text
reserve 5
consume 2
release 3
final available_quantity restored correctly
consumed_quantity remains 2
reserved_quantity becomes 0
```

---

## 16. Acceptance Criteria

This slice is accepted only when:

```text
ReservationLedger exists and exposes the approved API.
RedisScripts exists and centralizes Lua/script behavior.
Reserve/consume/release/expire/get_availability are implemented.
Mutating operations are atomic and idempotent.
Counter invariants are enforced.
Concurrent reserve tests pass without overselling.
Expiry cannot release consumed holds.
Redis unavailable behavior fails closed.
Redis keys/logs do not contain PII or secrets.
No Ash resource directly mutates Redis.
No checkout/payment/ticket/WhatsApp behavior is added.
All RED/GREEN tests pass.
Implementation notes document any divergence from VS-04A contract.
```

---

## 17. Implementation Notes for the Coding Agent

### Use

```text
Use the existing Redis client/wrapper if present.
Use Lua/script-backed atomic mutations for reserve/consume/release.
Use small, predictable return tuples.
Use explicit error atoms.
Use opaque, customer-safe public references.
Use bounded batch processing for expiry.
Use clear comments in RedisScripts explaining every KEYS/ARGV position.
Use tests to lock every critical invariant.
```

### Avoid

```text
Do not over-engineer a full distributed inventory subsystem.
Do not add GenServers unless existing infrastructure already requires them for Redis script management.
Do not add checkout workflows.
Do not add payment or ticket issuing behavior.
Do not use Postgres as fallback live inventory.
Do not perform application-side check-then-write for reserve.
Do not scatter Redis commands through controllers, LiveViews, Ash resources, or workers.
Do not store PII, tokens, or provider payloads in Redis inventory state.
```

---

## 18. TOON Prompt

| Field | Content |
|---|---|
| Task | Implement the atomic Redis inventory ledger for FastCheck Sales in `lib/fastcheck/sales/inventory/reservation_ledger.ex` and `lib/fastcheck/sales/inventory/redis_scripts.ex`. |
| Objective | Provide the hot inventory primitive used by every Sales channel so checkout can reserve, consume, release, expire, and read availability without overselling under concurrency. |
| Output | `ReservationLedger` module, centralized Redis script module, Redis inventory tests, concurrency tests, boundary tests, and implementation notes documenting any contract deviations. |
| Note | Use the existing Redis wrapper if present. Implement atomic script-backed reserve/consume/release behavior. Required Redis structures: inventory hash, holds zset, hold hash, order lock key, idempotency/dedupe key. TTLs: hold TTL from checkout policy; idempotency TTL bounded; dedupe TTL long enough for retries. Invalidation: inventory mutations may emit telemetry/PubSub hooks but must not build UI. Required indexes are not DB-facing in this slice, but future checkout depends on indexed offer/order/session paths from VS-01G. Do not modify Ash resources, checkout, Paystack, WhatsApp, ticket issuance, Attendees, scanner, or UI. Redis must be the hot layer; Postgres must not be used as fallback live counter. RED first: tests must fail for missing API, oversell, duplicate consume/release, expired consumed holds, Redis unavailable fallback, PII in inventory keys/logs, and boundary violations. GREEN only when no oversell is possible and all mutations are idempotent. |

---

## 19. Copy-Paste Agent Prompt

```text
You are implementing FastCheck Sales slice VS-04B — Atomic Inventory Ledger Implementation.

Read these docs first:
- docs/fastcheck_sales/SOURCE_DOCS/FastCheck_Sales_Ash_Atlas_Planning_Pack_v0.2.3_HARDENED.md
- docs/fastcheck_sales/SOURCE_DOCS/FastCheck_Sales_Vertical_Slice_Roadmap_v1.1.3_HARDENED.md
- The accepted VS-04A Inventory Ledger Contract pack

Goal:
Implement the Redis-backed atomic inventory ledger used by all Sales channels. FastCheck Sales is multi-channel, but WhatsApp is first. All channels must use this same inventory ledger.

Implement only the inventory boundary:
- lib/fastcheck/sales/inventory/reservation_ledger.ex
- lib/fastcheck/sales/inventory/redis_scripts.ex
- test/fastcheck/sales/inventory/*_test.exs
- optional test support under test/support only if needed

Required API:
- initialize_offer/2 or equivalent accepted by VS-04A
- reserve(offer_id, order_public_reference, quantity, ttl_seconds, idempotency_key)
- consume(offer_id, order_public_reference, quantity, idempotency_key)
- release(offer_id, order_public_reference, idempotency_key)
- expire_due_holds(now)
- get_availability(offer_id)

Rules:
- Use existing Redis wrapper/client if present.
- Reserve, consume, release, and expiry counter mutation must be atomic.
- Prefer Lua/scripts centralized in RedisScripts.
- No application-side check-then-write reservation logic.
- Mutating operations must be idempotent.
- Availability must never go negative.
- Expiry must never release consumed holds.
- Redis unavailable must fail closed. Do not use Postgres as fallback live counter.
- Do not modify Ash resources, checkout workflows, payments, WhatsApp, ticket issuance, Attendees, scanner, or UI.
- Do not store/log PII, Paystack payloads, Meta payloads, delivery tokens, or QR tokens in Redis inventory keys/events/logs.

RED/GREEN testing:
Write failing tests first for missing APIs, oversell prevention, idempotent reserve/consume/release, expiry safety, Redis-unavailable behavior, boundary violations, and PII/log safety. Then implement until green.

Success:
Concurrent reservation tests prove no oversell. Reserve/consume/release/expire/get_availability work through the approved Redis boundary. No other architectural layer is changed.
```

---

## 20. Human Review Checklist

Before marking this slice Done, verify:

```text
[ ] ReservationLedger API matches VS-04A contract or deviations are documented.
[ ] RedisScripts centralizes Lua/script behavior.
[ ] Reserve is atomic and idempotent.
[ ] Consume is atomic and idempotent.
[ ] Release is atomic and idempotent.
[ ] Expiry cannot release consumed or already released holds.
[ ] Concurrent reserve test proves no overselling.
[ ] Redis unavailable behavior fails closed.
[ ] No Postgres fallback live counter exists.
[ ] No Ash resource directly mutates inventory Redis keys.
[ ] No checkout/payment/ticket/WhatsApp/scanner/UI scope creep exists.
[ ] No PII/tokens/provider payloads appear in Redis keys, values, logs, or telemetry.
[ ] Tests include RED/GREEN coverage for failure and concurrency paths.
[ ] Performance review confirms hot path is Redis-only and O(1)/bounded.
```

---

## 21. Next Slice

```text
VS-04C — Inventory Reconciliation and Recovery
```

VS-04C must build on this ledger to handle Redis/Postgres reconciliation, restart recovery, degraded ledger repair, and operational recovery tooling. Do not pull that scope into VS-04B.
