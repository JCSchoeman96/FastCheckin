# FastCheck Sales Feature Planning Pack — VS-04A Inventory Ledger Contract Finalization

**Pack ID:** `0014_VS-04A_inventory-ledger-contract-finalization`  
**Repository path:** `docs/fastcheck_sales/feature_packs/0014_VS-04A_inventory-ledger-contract-finalization`  
**Slice:** `VS-04A`  
**Slice name:** Inventory Ledger Contract Finalization  
**Version:** `v1.0`  
**Date:** 2026-06-12  
**Status:** Planning/contract pack — no implementation code  
**Primary area:** Redis / Inventory / Concurrency / Checkout Contract / Tests  
**Depends on:** VS-00A, VS-00B, VS-00C, VS-00D, VS-01B, VS-01G, VS-03  
**Blocks:** VS-04B, VS-04C, VS-05, VS-14  
**Source docs:**

```text
docs/fastcheck_sales/SOURCE_DOCS/FastCheck_Sales_Ash_Atlas_Planning_Pack_v0.2.3_HARDENED.md
docs/fastcheck_sales/SOURCE_DOCS/FastCheck_Sales_Vertical_Slice_Roadmap_v1.1.3_HARDENED.md
```

---

## 1. Purpose

This pack finalizes the implementation contract for the Redis-backed inventory ledger used by FastCheck Sales checkout.

This is a **contract/planning slice**, not a coding slice. It must produce exact specifications that the later implementation slice `VS-04B — Atomic Inventory Ledger Implementation` can follow without inventing concurrency behavior.

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

The goal is to prevent overselling before any checkout, Paystack, WhatsApp, or ticket issuing work starts.

---

## 2. Ultimate Outcome

After VS-04A is complete:

```text
The Redis inventory key model is final.
The ReservationLedger public API is final.
The Lua script contract is final.
Hold TTL and expiry rules are final.
Idempotency behavior is final.
Consume/release semantics are final.
Redis restart/recovery rules are final.
Redis/Postgres reconciliation rules are final.
Checkout/payment-after-expiry inventory behavior is final.
RED/GREEN implementation test expectations are written before VS-04B.
No Redis Lua implementation exists yet.
No checkout code exists yet.
No Ash resource directly mutates Redis.
```

A coding agent implementing VS-04B must be able to implement the ledger from this contract without asking what `reserve`, `consume`, `release`, or `reconcile` means.

---

## 3. Scope

### In scope

```text
Finalize Redis key names and structures.
Finalize ReservationLedger operation signatures.
Finalize Lua input/output contracts.
Finalize hold lifecycle rules.
Finalize idempotency-key behavior.
Finalize lock behavior.
Finalize error codes and return shapes.
Finalize Redis unavailable behavior.
Finalize Redis restart/rebuild behavior.
Finalize Redis/Postgres reconciliation behavior.
Finalize checkout integration expectations.
Finalize payment-after-expiry inventory behavior.
Finalize PubSub/cache invalidation expectations.
Finalize RED/GREEN tests for VS-04B and VS-04C.
Document expected file paths for later implementation.
```

### Out of scope

```text
No Redis Lua implementation.
No Redis command implementation.
No Ash resource changes.
No migrations unless a documentation table or optional inventory snapshot has already been approved elsewhere.
No checkout session creation.
No Order workflow implementation.
No Paystack client or webhook behavior.
No WhatsApp or Meta API behavior.
No ticket issuing.
No Attendee creation.
No scanner hot-path changes.
No LiveView/admin UI.
```

---

## 4. Required Pre-Implementation Decisions

The coding/documentation agent must read and follow accepted outputs from:

```text
VS-00A State Machine and Failure Policy Finalization
VS-00B Security, PII, and Token Policy Finalization
VS-00C Inventory Recovery and Reconciliation Contract
VS-00D MVP Purchase Entry-Point and Launch Scope Decision
VS-01B Core Sales Resource Skeletons
VS-01G Index and Migration Verification
VS-03 Ticket Offer Management
```

### Required discovery step

Before writing or finalizing the contract, the agent must locate and document actual repository paths for:

```text
FastCheck.Sales domain module
FastCheck.Sales.TicketOffer resource
FastCheck.Sales.CheckoutSession resource
FastCheck.Sales.Order resource
existing Redis connection module or pool
existing Cachex configuration
existing Phoenix PubSub module
existing Oban worker naming conventions
existing test support helpers
existing event/offer ID type conventions
```

Do not assume names if the repository differs.

---

## 5. Domain and Boundary Details

### Ash domain referenced

```text
FastCheck.Sales
```

### Ash resources referenced, not modified

```text
FastCheck.Sales.TicketOffer
FastCheck.Sales.Order
FastCheck.Sales.OrderLine
FastCheck.Sales.CheckoutSession
FastCheck.Sales.StateTransition
```

### Plain Elixir boundary to define

```text
FastCheck.Sales.Inventory.ReservationLedger
FastCheck.Sales.Inventory.RedisScripts
```

These modules are the approved future boundary for Redis inventory behavior. Ash resources, controllers, LiveViews, workers, and WhatsApp flows must not mutate Redis inventory keys directly.

### Core authority split

```text
Postgres/Ash:
  durable offer configuration
  durable order and checkout intent
  durable payment/ticket state
  durable audit records

Redis:
  hot availability
  active holds
  hold expiry ledger
  short idempotency/lock state
  high-concurrency read path for availability

TicketOffer:
  durable configured inventory only
  not the live flash-sale counter
```

---

## 6. Redis Key Contract

The contract must finalize these keys or explicitly document any repository-specific alternative.

```text
sales:offer:{offer_id}:inventory
sales:offer:{offer_id}:holds
sales:hold:{public_reference}
sales:order:{public_reference}:lock
sales:inventory:dedupe:{operation}:{idempotency_key}
sales:inventory:events:{offer_id}
sales:event:{event_id}:offers
```

### Required structure details

#### `sales:offer:{offer_id}:inventory`

Recommended type:

```text
Redis hash
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
available_quantity must never become negative.
reserved_quantity must never become negative.
consumed_quantity must never exceed configured_quantity unless explicit oversell/manual-review policy exists.
revision increments on reserve/consume/release/reconcile.
ledger_state must support at least healthy, degraded, reconciliation_required, closed.
```

#### `sales:offer:{offer_id}:holds`

Recommended type:

```text
Redis sorted set
```

Required behavior:

```text
member: public_reference or hold_key
score: unix expiry timestamp in milliseconds or seconds, but the unit must be documented and consistent.
```

Rules:

```text
Expiry worker reads due holds by score.
Consume must remove hold from zset.
Release must remove hold from zset.
Expire must only release holds still in hold_attached/payment_link_sent/payment_started style state.
```

#### `sales:hold:{public_reference}`

Recommended type:

```text
Redis hash
```

Required fields:

```text
public_reference
offer_id
order_id or order_public_reference
quantity
status
idempotency_key
created_at
expires_at
consumed_at
released_at
last_operation
last_operation_at
```

Allowed statuses:

```text
held
consumed
released
expired
manual_review
```

Rules:

```text
Consumed holds must not be released by expiry.
Released/expired holds must not be consumed unless payment-after-expiry re-reserve policy explicitly allows a new hold.
Hold hash TTL must be longer than the active hold TTL so reconciliation/debugging remains possible.
```

#### `sales:order:{public_reference}:lock`

Recommended type:

```text
short-lived string key via SET NX PX
```

Rules:

```text
Used to serialize reserve/consume/release operations per order/public_reference.
Must have short TTL to avoid permanent lock.
Lock timeout behavior must return explicit error, not silently retry forever.
```

#### `sales:inventory:dedupe:{operation}:{idempotency_key}`

Recommended type:

```text
string or hash with TTL
```

Rules:

```text
Records operation result for idempotent retries.
TTL must exceed likely webhook/worker retry window.
Recommended minimum TTL: 24 hours for payment/consume-related operations.
```

#### `sales:inventory:events:{offer_id}`

Recommended type:

```text
Redis list or stream-like append-only event trail
```

Rules:

```text
Useful for debugging and reconciliation.
Must not be the only durable audit source.
Can be capped/trimmed.
Do not store PII.
```

---

## 7. ReservationLedger Public API Contract

The contract must define these public functions for future implementation.

```elixir
reserve(offer_id, order_public_reference, quantity, ttl_seconds, idempotency_key)
consume(offer_id, order_public_reference, quantity, idempotency_key)
release(offer_id, order_public_reference, idempotency_key)
expire_due_holds(now)
get_availability(offer_id)
reconcile_offer(offer_id)
mark_offer_degraded(offer_id, reason)
mark_offer_healthy(offer_id)
```

Exact arity may be adjusted to match project style, but the contract must preserve these inputs and behaviors.

### Common input rules

```text
offer_id must identify a valid durable TicketOffer.
order_public_reference must be opaque and customer-safe.
quantity must be positive integer.
ttl_seconds must be positive and bounded by checkout policy.
idempotency_key is required for mutating operations.
```

### Common output shape

Use an explicit tagged result shape. Recommended:

```elixir
{:ok, result_map}
{:error, error_code, metadata_map}
```

The contract must define exact error codes before VS-04B.

Required error code families:

```text
:offer_not_found
:offer_not_active
:invalid_quantity
:insufficient_inventory
:already_reserved
:already_consumed
:already_released
:hold_expired
:hold_not_found
:ledger_unavailable
:ledger_degraded
:lock_timeout
:reconciliation_required
:invalid_idempotency_key
:unexpected_redis_response
```

---

## 8. Operation Contracts

### 8.1 `reserve/5`

Purpose:

```text
Atomically reserve inventory for an order/checkout for a limited time.
```

Required behavior:

```text
Acquire order lock.
Validate ledger health.
Validate quantity > 0.
Check idempotency key.
If same idempotency key already reserved same hold, return previous success.
If existing hold exists for public_reference and is held, return idempotent success if quantity matches.
If existing hold quantity differs, return explicit conflict/manual-review error.
Check available_quantity >= quantity.
Decrement available_quantity.
Increment reserved_quantity.
Create/update hold hash with status held.
Add hold to offer holds zset with expiry score.
Record dedupe result.
Append non-PII inventory event.
Release lock.
Return hold key, expiry, available quantity, revision.
```

Forbidden behavior:

```text
Do not create Order or CheckoutSession records.
Do not call Ash actions from Lua.
Do not call Paystack.
Do not send WhatsApp.
Do not issue tickets.
Do not read availability from Postgres during hot reservation path except outside the atomic Redis script where explicitly approved.
```

### 8.2 `consume/4`

Purpose:

```text
Atomically convert a valid hold into sold/consumed inventory after verified payment and payment-after-expiry policy passes.
```

Required behavior:

```text
Acquire order lock.
Validate idempotency key.
If already consumed for same order/idempotency key, return idempotent success.
Load hold.
If hold is held and not expired, consume it.
If hold is expired/released, only consume if caller has performed approved payment-after-expiry re-reserve path.
Decrement reserved_quantity when consuming active hold.
Increment consumed_quantity.
Set hold status consumed.
Remove hold from zset.
Record consumed_at.
Record dedupe result.
Append non-PII inventory event.
Release lock.
Return consumed quantity, revision, and inventory summary.
```

Forbidden behavior:

```text
Do not issue tickets.
Do not mark order paid.
Do not create attendees.
Do not send messages.
```

### 8.3 `release/4`

Purpose:

```text
Atomically release an active hold back to availability when checkout is cancelled, expired, or explicitly released.
```

Required behavior:

```text
Acquire order lock.
Validate idempotency key.
If already released/expired, return idempotent success.
If already consumed, do not release; return already_consumed idempotent outcome.
If hold is held, decrement reserved_quantity and increment available_quantity.
Set hold status released.
Remove hold from zset.
Record released_at.
Record dedupe result.
Append non-PII inventory event.
Release lock.
Return inventory summary.
```

Forbidden behavior:

```text
Do not cancel orders directly.
Do not change payment state.
Do not revoke tickets.
```

### 8.4 `expire_due_holds/1`

Purpose:

```text
Find and expire due holds safely.
```

Required behavior:

```text
Read due hold members from zset by score.
For each due hold, call the same release/expiry-safe path or equivalent Lua script.
Only expire holds still held.
Never release consumed holds.
Return counts: expired, skipped_consumed, skipped_missing, failed.
Support batching to avoid loading all due holds into memory.
```

Forbidden behavior:

```text
Do not scan all orders from Postgres during hot expiry loop.
Do not mark orders expired unless the checkout/order expiry workflow owns that transition.
```

### 8.5 `get_availability/1`

Purpose:

```text
Read hot availability for active display/checkout decisions.
```

Required behavior:

```text
Read Redis inventory hash.
Return available, reserved, consumed, configured, ledger_state, revision.
If missing or degraded, return explicit error requiring fallback/reconciliation.
Do not silently rebuild inside public read unless contract allows it.
```

### 8.6 `reconcile_offer/1`

Purpose:

```text
Rebuild or repair Redis inventory from durable Postgres/Ash state when needed.
```

Required behavior:

```text
Load durable TicketOffer configured quantity.
Load relevant durable orders/checkout sessions/ticket issues through indexed queries.
Calculate consumed inventory from issued/non-revoked tickets or accepted durable issue model.
Calculate active holds from non-expired checkout sessions that still have valid Redis/Pg hold state if possible.
Set inventory hash to deterministic repaired values.
Mark ledger healthy or reconciliation_required based on outcome.
Emit telemetry and non-PII logs.
Return reconciliation summary.
```

Rules:

```text
Postgres/Ash durable state wins over Redis if they disagree.
Reconciliation must be explicit and observable.
Checkout should not proceed while ledger_state is unknown or reconciliation_required.
```

---

## 9. Payment-After-Expiry Inventory Rules

The contract must preserve the accepted payment-after-expiry policy from VS-00A.

Required cases:

| Case | Inventory behavior |
|---|---|
| Payment verified before hold expiry | `consume` the existing hold. |
| Payment verified after hold expiry and inventory still available | create a new reservation/consume path explicitly approved by the policy, then issue. |
| Payment verified after hold expiry and inventory unavailable | move order/payment to manual review; do not issue automatically. |
| Duplicate webhook for already consumed inventory | return idempotent success; do not consume again. |
| Expiry worker races with payment consume | lock/idempotency must allow only one safe outcome. |

Required contract detail:

```text
Define whether late-payment re-reserve uses reserve+consume or a dedicated consume_after_expiry operation.
```

Recommendation:

```text
Use explicit reserve+consume with a new late-payment idempotency key, or define consume_after_expiry as a separate operation in the contract.
Do not hide this behavior inside normal consume without clear preconditions.
```

---

## 10. Concurrency and Race Conditions

The contract must explicitly handle these races:

```text
Two customers reserve the last ticket at the same time.
Same customer retries reserve after network timeout.
Checkout expiry worker releases hold while Paystack verification worker consumes hold.
Webhook duplicate triggers consume twice.
Admin disables offer while reservation is attempted.
Redis lock expires mid-operation.
Redis command succeeds but caller times out.
Redis restarts after reserve but before checkout session persists.
Redis restarts after payment is verified but before consume succeeds.
Reconciliation runs while checkout requests arrive.
```

Required rule:

```text
The ledger must fail closed during uncertainty.
If ledger_state is degraded or reconciliation_required, public checkout must stop accepting new reservations for that offer until health is restored.
```

---

## 11. Cache, TTL, and PubSub Rules

### Hold TTL

The contract must specify:

```text
default hold TTL
minimum hold TTL
maximum hold TTL
whether TTL is channel-specific
whether TTL can be extended
who may extend it
how extension is audited
```

Recommended initial direction:

```text
Default hold TTL: 10–15 minutes.
Shorter TTL may be used during flash-sale pressure.
Extensions should be rare and explicit.
```

### Cache invalidation

Required invalidation triggers:

```text
reserve -> availability changed
consume -> availability changed and ticket issuance path can proceed
release -> availability changed
expire -> availability changed
reconcile -> availability changed and ledger health changed
TicketOffer update/disable/archive -> offer display cache invalidation
```

### PubSub

Required broadcast topics/events must be defined before implementation.

Recommended topic pattern:

```text
sales:event:{event_id}:offers
sales:offer:{offer_id}:availability
```

Recommended event names:

```text
offer_availability_changed
inventory_ledger_degraded
inventory_reconciled
hold_expired
```

No PII may be broadcast.

---

## 12. Performance and Scaling Review

### Hot / warm / cold classification

| Data | Layer | Rule |
|---|---|---|
| active availability | Redis hot | no Postgres read on every checkout click |
| active holds | Redis hot | hash + zset |
| configured offer data | Postgres cold + Cachex/Redis warm | invalidate on offer mutation |
| checkout intent | Postgres durable | not the atomic counter |
| issued tickets | Postgres durable | source for reconciliation |
| admin dashboards | Postgres indexed + cached aggregates | no peak table scans |

### Required performance gates

```text
Reserve/consume/release must be O(1) or bounded by small key operations.
Expiry must be batched by zset score, not full scan.
Availability reads must be Redis-first.
Reconciliation may use Postgres but must be operator/system controlled, not hot path.
No checkout path may perform large table scans.
No Redis event trail may grow unbounded without trimming policy.
```

Target posture:

```text
Sub-100ms inventory operation target under normal load.
Safe under duplicate execution and high concurrency.
Fail closed rather than oversell.
```

---

## 13. Security and PII Rules

Inventory keys and events must not include customer names, emails, phone numbers, Paystack access codes, authorization URLs, raw webhook payloads, delivery tokens, or QR tokens.

Allowed identifiers:

```text
offer_id
order_public_reference
idempotency_key hash/reference
correlation_id
quantity
operation status
non-PII timestamps
```

Logging rules:

```text
Log operation type, offer_id, public_reference, quantity, result code, correlation_id.
Do not log raw customer PII or provider payloads.
Do not log plaintext tokens.
```

---

## 14. Required Documentation Outputs

The coding/documentation agent must create or update a contract document, preferably:

```text
docs/sales/inventory_ledger_contract.md
```

If the repository has a different docs structure, use the existing convention and document the actual path.

The contract document must include:

```text
Redis key model
Redis data structure choices
ReservationLedger public API
Lua script names and operation contracts
input validation rules
output shape and error codes
idempotency rules
lock rules
hold TTL policy
payment-after-expiry inventory behavior
expiry worker contract
reconciliation algorithm
Redis failure policy
cache/PubSub invalidation policy
performance/scaling review
security/PII rules
RED/GREEN test plan for VS-04B and VS-04C
```

---

## 15. RED/GREEN Documentation Tests

This slice is planning-only. RED/GREEN tests are documentation/contract tests, not implementation tests yet.

### RED tests — fail the pack if any are true

```text
No ReservationLedger API contract exists.
No Redis key structure is defined.
No idempotency behavior is defined.
No hold TTL policy is defined.
No payment-after-expiry inventory behavior is defined.
No Redis unavailable behavior is defined.
No Redis restart/recovery behavior is defined.
No reconciliation algorithm is defined.
No output/error shape is defined.
No concurrency/race list exists.
No rule forbids Ash resources/controllers/workers from direct Redis inventory mutation.
No RED/GREEN test expectations exist for VS-04B.
Contract allows checkout to continue while ledger health is unknown.
Contract allows negative availability.
Contract stores customer PII in Redis inventory keys/events.
```

### GREEN tests — pass only when all are true

```text
ReservationLedger public API is final enough for implementation.
Redis key names and data structures are explicit.
Reserve/consume/release/expire/get_availability/reconcile behavior is specified.
Idempotency rules are explicit for every mutating operation.
Lock behavior is explicit.
Hold TTL and expiry behavior are explicit.
Payment-after-expiry inventory behavior is explicit.
Redis unavailable and restart/recovery behavior are explicit.
Reconciliation has deterministic Postgres/Ash source-of-truth rules.
Cache and PubSub invalidation rules are defined.
Performance and scaling constraints are defined.
Security and PII constraints are defined.
VS-04B implementation test expectations are listed.
No implementation code is added in this slice.
```

---

## 16. Future Implementation Test Expectations for VS-04B

VS-04B must implement tests proving:

```text
reserve succeeds when inventory is available.
reserve fails when inventory is insufficient.
reserve is idempotent for the same idempotency key.
reserve returns conflict for same order with different quantity unless policy allows replacement.
reserve never makes availability negative under concurrency.
consume converts held inventory to consumed inventory.
consume is idempotent for duplicate calls.
consume does not release or double-consume expired/released holds.
release returns held inventory to availability.
release is idempotent.
release does not release consumed holds.
expire_due_holds only expires due held holds.
expiry does not release consumed holds.
get_availability returns Redis ledger summary.
Redis unavailable returns explicit ledger_unavailable error.
ledger_degraded prevents new reservations.
concurrent reservations for last ticket result in exactly one success.
payment consume racing with expiry results in one safe outcome.
no PII is stored in inventory keys/events/logs.
```

VS-04C must implement tests proving:

```text
reconcile_offer rebuilds Redis from durable Postgres/Ash state.
reconcile_offer corrects Redis availability when Redis says more available than durable state allows.
reconcile_offer marks ledger healthy only after deterministic repair.
checkout is blocked while ledger is reconciliation_required.
```

---

## 17. TOON Coding-Agent Prompt

| Field | Content |
|---|---|
| Task | Finalize the Redis inventory ledger contract for FastCheck Sales in `docs/sales/inventory_ledger_contract.md` or the repository’s equivalent docs path. Do not implement Redis Lua or runtime code. |
| Objective | Produce an implementation-ready contract for `FastCheck.Sales.Inventory.ReservationLedger` so VS-04B can implement atomic reservation, consume, release, expiry, and availability behavior without inventing concurrency rules. |
| Output | A contract document covering Redis keys, data structures, public API, Lua script contracts, input/output shapes, error codes, idempotency, locks, TTLs, payment-after-expiry behavior, expiry worker behavior, Redis failure/recovery, reconciliation, cache/PubSub invalidation, performance constraints, PII rules, and RED/GREEN test expectations. Update any planning index/manifest if the repo uses one. |
| Note | Do not write implementation code. Do not create Ash resources or migrations. Do not call Redis, Paystack, Meta, WhatsApp, Attendees, scanner, or checkout code. The ledger must fail closed during unknown/degraded state. All channels — WhatsApp-first, admin-assisted, web checkout, and internal pilot — must use the same ReservationLedger. Required Redis structures: hash for inventory, zset for holds, hash for hold details, short lock key, dedupe key, optional event list/stream. TTLs, idempotency, error codes, PubSub topics, and reconciliation rules must be explicit. No PII in Redis keys/events/logs. |

---

## 18. Copy-Paste Agent Prompt

```text
You are implementing feature planning pack 0014_VS-04A_inventory-ledger-contract-finalization for FastCheck Sales.

Goal:
Finalize the Redis inventory ledger contract only. Do not implement Redis Lua or runtime code.

Context:
FastCheck Sales is multi-channel, but WhatsApp is first. WhatsApp, admin-assisted sales, web checkout sales, and internal pilot sales must all use the same Sales core and the same Redis inventory ledger. TicketOffer is durable offer configuration only. Redis owns hot availability and active holds. Postgres/Ash owns durable state and recovery truth.

Primary output:
Create or update docs/sales/inventory_ledger_contract.md, or the repository’s equivalent docs path.

The contract must define:
- Redis key model
- Redis data structures
- ReservationLedger public API
- reserve/consume/release/expire/get_availability/reconcile operation behavior
- input validation rules
- output shape and error codes
- idempotency behavior
- lock behavior
- hold TTL policy
- payment-after-expiry inventory behavior
- Redis unavailable behavior
- Redis restart/recovery behavior
- deterministic Redis/Postgres reconciliation
- cache and PubSub invalidation rules
- performance/scaling constraints
- security and PII rules
- RED/GREEN test expectations for VS-04B and VS-04C

Forbidden:
- no Redis Lua implementation
- no Redis runtime code
- no Ash resource changes
- no migrations unless existing repo process requires docs index only
- no checkout code
- no Paystack code
- no Meta/WhatsApp code
- no ticket issuance
- no Attendee/scanner changes
- no UI

Required safety rules:
- inventory ledger fails closed when degraded or unknown
- no checkout may bypass ReservationLedger
- reserve/consume/release must be idempotent
- availability must never go negative
- expiry must never release consumed holds
- duplicate webhooks/workers must not double-consume inventory
- Redis recovery must reconcile from durable Postgres/Ash state
- no customer PII, tokens, Paystack payloads, or Meta payloads in Redis inventory keys/events/logs

Before editing, discover actual repo paths for Sales, TicketOffer, CheckoutSession, Order, Redis connection, Cachex, PubSub, Oban, tests, and docs. Document any deviations from the expected paths.
```

---

## 19. Human Review Checklist

Before marking this pack accepted, verify:

```text
The contract is implementation-ready but contains no implementation code.
Redis keys and structures are explicit.
ReservationLedger operations are explicit.
Lua behavior is specified enough for VS-04B.
Idempotency is defined for reserve, consume, release, and expiry.
Error codes are explicit.
Hold TTL policy is explicit.
Payment-after-expiry inventory behavior is explicit.
Concurrency/race cases are covered.
Redis unavailable/restart/recovery behavior is explicit.
Reconciliation from durable Postgres/Ash state is deterministic.
Ledger degraded/unknown state fails closed.
Cache and PubSub rules are explicit.
Performance constraints prevent hot Postgres reads during checkout.
PII rules prevent sensitive values in Redis inventory keys/events/logs.
RED/GREEN tests for VS-04B and VS-04C are defined.
All sales channels are required to use the same ledger.
```

---

## 20. Success Criteria

This pack is complete when a future implementation agent can build `VS-04B — Atomic Inventory Ledger Implementation` without making new architectural decisions about:

```text
keys
structures
operation names
operation inputs
operation outputs
error codes
idempotency
TTL
locking
expiry
payment-after-expiry behavior
failure behavior
reconciliation
cache invalidation
PubSub
security
performance
```

If any of those still require interpretation, this pack is not done.
