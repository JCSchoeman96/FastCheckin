# FastCheck Sales Feature Planning Pack — VS-00C Inventory Recovery and Reconciliation Contract

**Pack ID:** `0003_VS-00C_inventory-recovery-and-reconciliation-contract`  
**Repository path:** `docs/fastcheck_sales/feature_packs/0003_VS-00C_inventory-recovery-and-reconciliation-contract/`  
**Slice:** `VS-00C`  
**Slice name:** Inventory Recovery and Reconciliation Contract  
**Version:** `v1.0`  
**Date:** 2026-06-12  
**Status:** Ready for planning after VS-00 and VS-00A alignment  
**Primary area:** Redis / Architecture / Inventory Safety / Docs  
**Depends on:** VS-00, VS-00A  
**Blocks:** VS-01A+, VS-04A, VS-04B, VS-04C, VS-05, VS-14, VS-22, VS-23A  
**Source docs:**

```text
docs/fastcheck_sales/SOURCE_DOCS/FastCheck_Sales_Ash_Atlas_Planning_Pack_v0.2.3_HARDENED.md
docs/fastcheck_sales/SOURCE_DOCS/FastCheck_Sales_Vertical_Slice_Roadmap_v1.1.3_HARDENED.md
```

---

## 1. Purpose

This pack defines the Redis/Postgres inventory recovery, reconciliation, reservation, consume, release, expiry, cache, and failure contract for FastCheck Sales before any Redis Lua, checkout, payment, or ticket issuance implementation begins.

This is a planning and contract slice only. It must produce documentation precise enough that later coding agents cannot accidentally build checkout flows that oversell, lose holds, double-release inventory, consume expired holds, issue tickets after inventory vanished, or keep sales open while inventory state is unhealthy.

Core product framing to preserve:

```text
FastCheck Sales is multi-channel, but WhatsApp is first.

Primary production customer channel:
  WhatsApp via Meta Cloud API

Secondary supported Sales paths:
  admin-assisted sales
  web checkout sales
  internal pilot sales

All channels must use the same Sales core:
  Redis inventory reservation
  Paystack server-side verification
  idempotent ticket issuance
  DeliveryAttempt audit
  scanner-safe revocation
```

Inventory principle:

```text
WhatsApp, web checkout, admin-assisted sales, and internal pilot flows are interfaces only.
No interface may bypass the shared Redis inventory reservation ledger.
```

---

## 2. Ultimate Outcome

After VS-00C is complete, the project has accepted inventory contracts for:

```text
Redis key structures
Redis data structures
reserve/consume/release/expire operation contracts
idempotency model
hold TTL model
inventory health model
Redis unavailable behavior
Redis restart recovery behavior
Redis/Postgres reconciliation rules
checkout/payment-after-expiry inventory behavior
cache invalidation rules
PubSub availability broadcasting rules
RED/GREEN documentation tests
future RED/GREEN implementation test expectations
```

No implementation code should be written in this slice.

---

## 3. Scope

### In scope

```text
Define the inventory authority split between Redis and Postgres/Ash.
Define Redis keys and data structures.
Define ReservationLedger operation contracts.
Define idempotency keys and lock behavior.
Define checkout hold TTL and expiry behavior.
Define Redis unavailable behavior.
Define Redis restart recovery behavior.
Define Redis/Postgres reconciliation behavior.
Define late payment / expired hold behavior from an inventory perspective.
Define cache and PubSub invalidation rules.
Define operational health checks before opening sales.
Define failure-mode tests for future implementation slices.
Define RED/GREEN documentation validation tests.
```

### Out of scope

```text
No Elixir implementation code.
No Redis Lua scripts.
No Ash resource modules.
No database migrations.
No CheckoutSession implementation.
No Paystack implementation.
No Meta/WhatsApp implementation.
No ticket issuance implementation.
No Oban worker implementation.
No admin UI.
No scanner changes.
```

---

## 4. Domain and Ash Details

### Ash domain

```text
FastCheck.Sales
```

### Ash resources referenced but not implemented

```text
FastCheck.Sales.TicketOffer
FastCheck.Sales.Order
FastCheck.Sales.OrderLine
FastCheck.Sales.CheckoutSession
FastCheck.Sales.PaymentAttempt
FastCheck.Sales.PaymentEvent
FastCheck.Sales.TicketIssue
FastCheck.Sales.StateTransition
```

### Plain Elixir modules to be planned later

```text
FastCheck.Sales.Inventory.ReservationLedger
FastCheck.Sales.Inventory.RedisScripts
FastCheck.Workers.ExpireCheckoutSessionWorker
FastCheck.Workers.EventSyncVersionAggregatorWorker
```

### Non-Ash boundary rules

```text
Ash resources may store Redis keys and inventory-related status snapshots.
Ash resources must not run Redis Lua.
Ash resources must not mutate Redis inventory directly.
Controllers and LiveViews must not mutate Redis inventory directly.
WhatsApp flows must not mutate Redis inventory directly.
Admin-assisted sales must not mutate Redis inventory directly.
All inventory mutation must go through FastCheck.Sales.Inventory.ReservationLedger.
```

### Ash resource inventory-facing fields

The future implementation will likely use these existing/planned fields:

```text
TicketOffer:
  id
  event_id
  configured_quantity_available
  initial_quantity
  sales_enabled
  starts_at
  ends_at
  lock_version
  archived_at

Order:
  id
  public_reference
  event_id
  source_channel
  status
  expires_at
  paid_at
  cancelled_at
  expired_at
  refunded_at
  lock_version

OrderLine:
  id
  sales_order_id
  ticket_offer_id
  quantity

CheckoutSession:
  id
  sales_order_id
  status
  redis_hold_key
  hold_token
  hold_quantity
  expires_at
  released_at
  expired_at
  lock_version

TicketIssue:
  id
  sales_order_id
  sales_order_line_id
  line_item_sequence
  status
  scanner_status
```

This slice must document how these fields interact with Redis, but it must not implement the fields.

---

## 5. Required Files / Artifacts

The coding agent should create documentation artifacts only.

Recommended repo paths:

```text
docs/fastcheck_sales/slices/VS-00C_INVENTORY_RECOVERY_AND_RECONCILIATION_CONTRACT.md
docs/fastcheck_sales/inventory/INVENTORY_MASTER_CONTRACT.md
docs/fastcheck_sales/inventory/INVENTORY_AUTHORITY_MODEL.md
docs/fastcheck_sales/inventory/REDIS_KEY_STRUCTURE.md
docs/fastcheck_sales/inventory/RESERVATION_LEDGER_OPERATION_CONTRACT.md
docs/fastcheck_sales/inventory/INVENTORY_IDEMPOTENCY_AND_LOCKING.md
docs/fastcheck_sales/inventory/HOLD_TTL_AND_EXPIRY_POLICY.md
docs/fastcheck_sales/inventory/REDIS_FAILURE_AND_RECOVERY_POLICY.md
docs/fastcheck_sales/inventory/REDIS_POSTGRES_RECONCILIATION_POLICY.md
docs/fastcheck_sales/inventory/INVENTORY_CACHE_AND_PUBSUB_POLICY.md
docs/fastcheck_sales/inventory/INVENTORY_HEALTH_AND_LAUNCH_GATES.md
docs/fastcheck_sales/inventory/INVENTORY_TEST_PLAN.md
```

If the repo already has a different docs convention, follow the existing convention but keep names explicit and searchable.

---

## 6. Required Contract Format

Every inventory contract document must include:

```text
purpose
scope
authority model
actors/callers allowed
callers forbidden
Redis keys involved
Redis data structures involved
Postgres/Ash records involved
operation preconditions
operation outputs
idempotency behavior
error behavior
retry behavior
cache invalidation behavior
PubSub broadcast behavior
required future tests
acceptance criteria
```

Every policy must explicitly say whether it applies to:

```text
WhatsApp sales
web checkout sales
admin-assisted sales
internal pilot sales
```

Default rule:

```text
The inventory policy applies to all sales channels unless the policy explicitly says otherwise.
```

---

## 7. Inventory Authority Model

The authority model must be explicit.

### Required decision

```text
Redis owns hot operational inventory state during active sales.
Postgres/Ash owns durable sales intent, orders, checkout sessions, payments, issued-ticket audit, and recovery source data.
```

### Hot, warm, and cold data classification

| Data | Layer | Notes |
|---|---|---|
| active availability counter | Redis hot | Used by checkout, WhatsApp, web/admin availability display. |
| active holds | Redis hot | Must use hash/zset pattern and TTL/expiry ledger. |
| order/checkout intent | Postgres/Ash cold durable | Never use Postgres as the immediate flash-sale counter. |
| configured offer inventory | Postgres/Ash cold durable | Source for initialization and reconciliation. |
| offer display cache | Cachex/Redis warm | Cachex 1–5 min, Redis 30 min. |
| payment/webhook dedupe | Redis warm/hot + Postgres durable event | SETNX-style dedupe plus unique DB identity. |
| real-time availability updates | Phoenix PubSub/LiveView push | No polling loops for active dashboards. |
| analytics/occupancy summaries | Redis/materialized/cached aggregates | No large table scans during peak. |

### Non-negotiable rules

```text
No checkout may bypass ReservationLedger.
No WhatsApp flow may bypass ReservationLedger.
No web checkout may bypass ReservationLedger.
No admin-assisted sale may bypass ReservationLedger unless a documented manual override exists and is audited.
No ticket may be issued merely because Postgres says an order exists.
No ticket may be issued after hold expiry unless payment-after-expiry recovery rules re-reserve or manual-review the order.
No Redis-unhealthy sale may continue accepting reservations.
```

---

## 8. Required Redis Key Structure

The Redis key structure document must define each key, type, TTL/expiry behavior, owner module, allowed operations, and invalidation/broadcast rules.

### Required inventory keys

```text
sales:offer:{offer_id}:meta
sales:offer:{offer_id}:available
sales:offer:{offer_id}:holds
sales:hold:{public_reference}
sales:order:{public_reference}:lock
sales:inventory:events:{offer_id}
sales:inventory:health:{offer_id}
sales:event:{event_id}:offers
```

### Required data structures

| Key | Redis type | Purpose |
|---|---|---|
| `sales:offer:{offer_id}:meta` | hash | Config snapshot: event_id, configured quantity, sales window, version. |
| `sales:offer:{offer_id}:available` | string integer or hash field | Hot available quantity counter for general admission style offers. |
| `sales:offer:{offer_id}:holds` | sorted set | Hold expiry ledger: member = public_reference/hold key, score = expiry timestamp. |
| `sales:hold:{public_reference}` | hash | Hold detail: offer_id, quantity, order ref, status, idempotency key, expires_at. |
| `sales:order:{public_reference}:lock` | string with short TTL | Per-order short lock for reserve/consume/release. |
| `sales:inventory:events:{offer_id}` | list or stream-like list | Optional operational audit trail for reserve/consume/release/expire/reconcile. |
| `sales:inventory:health:{offer_id}` | hash/string | Health state: healthy, rebuilding, degraded, closed. |
| `sales:event:{event_id}:offers` | string/json/hash | Warm offer display cache, TTL 30m. |

### Optional future seat-specific structures

If the product later adds reserved seating instead of general admission, the contract must reserve these patterns now without implementing them:

```text
sales:seatmap:{event_id}:{offer_id}          # Redis hash for seat metadata/status summary
sales:seatbits:{event_id}:{offer_id}         # Redis bitmap using SETBIT pattern for occupied/held seats
sales:seat_holds:{event_id}:{offer_id}       # sorted set for seat hold expiry
```

Do not implement seat maps in the current general-admission MVP unless the event model already requires it.

---

## 9. ReservationLedger Operation Contract

The future `FastCheck.Sales.Inventory.ReservationLedger` contract must expose exactly controlled operations. This slice documents the contract only.

### Required operations

```text
initialize_offer(offer_id, configured_quantity, version, metadata)
reserve(offer_id, order_public_reference, quantity, ttl_seconds, idempotency_key)
consume(offer_id, order_public_reference, quantity, idempotency_key)
release(offer_id, order_public_reference, idempotency_key)
expire_due_holds(now)
get_availability(offer_id)
mark_offer_health(offer_id, health_state, reason)
reconcile_offer(offer_id)
```

### Forbidden operations

```text
direct Redis mutation from controllers
direct Redis mutation from LiveViews
direct Redis mutation from WhatsApp handlers
direct Redis mutation from Ash resources
direct decrement/increment outside ReservationLedger
manual Redis CLI fixes during live sale without runbook and audit
```

### Standard operation result shape

Every operation contract must define a result shape like:

```text
:ok result with structured data
:error result with machine-readable reason
idempotent success result for duplicate safe retries
manual_review_required result where human intervention is needed
```

Recommended result fields:

```text
status
offer_id
order_public_reference
quantity
available_after
hold_key
expires_at
idempotency_key
reason
correlation_id
```

---

## 10. Operation Semantics

## 10.1 `initialize_offer/4`

Purpose:

```text
Initialize Redis hot inventory for a sellable offer from durable TicketOffer configuration.
```

Preconditions:

```text
TicketOffer exists.
TicketOffer is not archived.
Configured quantity is non-negative.
Offer version/lock_version is known.
No active inconsistent Redis state exists unless reconcile mode is explicit.
```

Rules:

```text
Must not erase active holds unless recovery policy explicitly allows rebuild.
Must store offer metadata/version.
Must mark inventory health healthy only after initialization succeeds.
Must publish availability change when initialized.
```

## 10.2 `reserve/5`

Purpose:

```text
Atomically reserve quantity for a checkout/order and create a timed hold.
```

Preconditions:

```text
Inventory health is healthy.
Offer is sales_enabled and within sales window.
Quantity is positive.
Quantity does not exceed max_per_order.
Order public_reference is present.
Idempotency key is present.
```

Rules:

```text
Reserve must be atomic.
Reserve must decrement hot availability only once.
Reserve must create/update the hold hash.
Reserve must add the hold to the zset expiry ledger.
Reserve must be idempotent for the same order/idempotency key.
Reserve must reject if insufficient availability exists.
Reserve must reject if inventory health is degraded/rebuilding/closed.
```

Required outcomes:

| Case | Outcome |
|---|---|
| enough inventory | hold created, availability decremented, expiry recorded |
| insufficient inventory | no mutation, return insufficient_inventory |
| duplicate reserve same idempotency | return existing hold / idempotent success |
| duplicate reserve different quantity | return conflict/manual_review_required |
| Redis unhealthy | reject with inventory_unavailable |

## 10.3 `consume/4`

Purpose:

```text
Convert a valid hold into sold/consumed inventory after verified payment and fulfillment eligibility.
```

Preconditions:

```text
Order payment verification succeeded.
Hold exists or payment-after-expiry recovery has re-reserved inventory.
Hold belongs to order_public_reference.
Quantity matches order lines.
Idempotency key is present.
```

Rules:

```text
Consume must be idempotent.
Consume must not decrement availability again if reserve already decremented availability.
Consume must mark hold as consumed/sold.
Consume must remove or mark the zset hold so expiry cannot release it.
Consume must reject expired/unavailable hold unless late-payment recovery has re-reserved.
Consume must publish availability/sold update if needed.
```

Required outcomes:

| Case | Outcome |
|---|---|
| valid active hold | mark consumed and return success |
| already consumed same idempotency | idempotent success |
| missing hold but order already ticket_issued | idempotent success with existing issued state |
| missing/expired hold before ticket issue | require payment-after-expiry policy |
| quantity mismatch | manual_review_required |

## 10.4 `release/3`

Purpose:

```text
Release a valid unconsumed hold and return inventory to availability.
```

Preconditions:

```text
Hold exists.
Hold is not consumed.
Idempotency key is present.
Release reason is known.
```

Rules:

```text
Release must be idempotent.
Release must increment availability exactly once.
Release must not release consumed holds.
Release must mark hold released or remove it consistently.
Release must remove/reconcile the zset entry.
Release must publish availability update where needed.
```

Required outcomes:

| Case | Outcome |
|---|---|
| active hold | released and availability incremented |
| already released | idempotent success |
| consumed hold | no availability increment; return already_consumed |
| missing hold | safe no-op or manual_review depending Postgres state |

## 10.5 `expire_due_holds/1`

Purpose:

```text
Find due holds from the zset expiry ledger and release only those still active/unconsumed.
```

Rules:

```text
Expiry must be safe under late worker execution.
Expiry must not release consumed holds.
Expiry must be batched and bounded.
Expiry must not load unbounded hold sets into memory.
Expiry must record/emit metrics for expired count, skipped consumed count, and errors.
```

Required outcomes:

| Case | Outcome |
|---|---|
| expired active hold | release inventory exactly once |
| expired consumed hold | skip; no availability increment |
| missing hold hash but zset member exists | remove stale zset member and record anomaly |
| Redis error mid-batch | retry safely; no double-release |

## 10.6 `get_availability/1`

Purpose:

```text
Read hot availability for display and checkout eligibility.
```

Rules:

```text
Must read Redis hot state during active sale.
Must not scan Postgres during checkout traffic.
Must return health/degraded status with availability.
Must allow stale/unknown markers for UI display if Redis is degraded.
```

## 10.7 `reconcile_offer/1`

Purpose:

```text
Compare Redis hot state with durable Postgres/Ash state and repair or mark manual intervention required.
```

Rules:

```text
Must be safe to run repeatedly.
Must not reopen sales while inconsistent.
Must prefer durable issued-ticket/order facts over Redis counters.
Must produce a reconciliation report.
Must mark inventory health rebuilding/degraded during reconciliation.
```

---

## 11. Idempotency and Locking Contract

### Required idempotency keys

```text
reserve:
  sales_order_id or public_reference + checkout_session_id + action + attempt/version

consume:
  sales_order_id + payment_attempt_id/provider_reference + action

release:
  checkout_session_id or public_reference + release reason + action

expire:
  hold_key + expiry timestamp + action

reconcile:
  offer_id + reconciliation run id
```

### Locking rules

```text
Use short Redis locks for per-order operations.
Do not use one global inventory lock for all offers.
Do not hold locks while performing external HTTP.
Do not hold locks while performing slow Postgres queries.
Lua/atomic scripts must perform only bounded Redis work.
Postgres optimistic locking still applies to durable order/checkout transitions.
```

### Duplicate execution rules

```text
Duplicate reserve must not double-decrement availability.
Duplicate consume must not double-consume or double-issue tickets.
Duplicate release must not double-increment availability.
Duplicate expiry must not double-release.
Duplicate reconciliation must not corrupt active state.
```

---

## 12. Hold TTL and Expiry Policy

The hold TTL policy must be explicit before checkout implementation.

### Required decisions

```text
default checkout hold TTL
minimum checkout hold TTL
maximum checkout hold TTL
whether TTL differs by sales channel
whether admin-assisted sales can use longer holds
whether WhatsApp conversation delays require special messaging
how close-to-expiry payment starts are handled
how expired payment links are handled
```

### Recommended defaults

```text
Public/WhatsApp checkout hold TTL: 10–15 minutes.
Admin-assisted hold TTL: same as public by default unless explicitly configured.
Internal pilot TTL: may be longer but must not be used for public sales.
```

### Expiry rules

```text
CheckoutSession expires_at must align with Redis hold expiry.
Redis zset score is the operational expiry authority.
Postgres CheckoutSession is durable intent and audit.
Expiry worker must reconcile both.
Customer messages must be truthful when a payment is pending or late.
```

---

## 13. Redis Failure and Recovery Policy

The failure policy must cover at least these cases.

| Failure | Required behavior |
|---|---|
| Redis unavailable during checkout | Do not accept new reservations. Show temporary unavailable/manual review. |
| Redis unavailable after payment verification | Do not blindly issue. Move to manual_review or retry safe consume depending known hold state. |
| Redis restarts and loses volatile holds | Close/degrade affected offers, rebuild/reconcile from Postgres before reopening. |
| Redis says available but Postgres/issued tickets disagree | Durable issued-ticket/order facts win; reconcile Redis downward. |
| Postgres order awaiting payment but Redis hold missing | Apply checkout expiry/payment-after-expiry policy. |
| Duplicate release/consume after worker retry | Must be idempotent and safe. |
| Expiry worker runs late | Expire only still-active holds. Never release consumed holds. |
| Reconciliation detects negative availability | Mark unhealthy/manual review; do not continue sales. |
| Reconciliation detects orphaned holds | Decide release/expire/manual-review by hold/order state. |

No flash-sale checkout should proceed while inventory ledger health is unknown.

---

## 14. Redis/Postgres Reconciliation Policy

The reconciliation policy must define how to compute expected availability.

### Required durable facts

```text
TicketOffer.configured_quantity_available or initial_quantity
Order statuses
CheckoutSession statuses and expires_at
OrderLine quantities
TicketIssue issued/revoked states
PaymentAttempt verified_success/manual_review states
```

### Recommended reconciliation formula for general admission

The exact implementation may differ, but the contract must define a deterministic formula like:

```text
configured_quantity
- consumed_quantity_from_issued_or_paid_fulfillment_orders
- active_hold_quantity_from_valid_checkout_sessions
= expected_available
```

Where:

```text
consumed_quantity_from_issued_or_paid_fulfillment_orders:
  orders/ticket issues that are paid_verified, fulfillment_queued, ticket_issued, or partially_issued according to the accepted state matrix

active_hold_quantity_from_valid_checkout_sessions:
  checkout sessions still within expiry and not released/consumed/cancelled
```

### Reconciliation outputs

Every reconciliation run must produce a report containing:

```text
offer_id
event_id
started_at
finished_at
health_before
health_after
redis_available_before
redis_available_after
expected_available
active_hold_count
orphan_hold_count
consumed_count
released_count
expired_count
manual_review_required?
anomalies
```

### Repair rules

```text
If Redis can be safely adjusted to expected_available, repair and record report.
If active holds are ambiguous, mark degraded/manual_review; do not guess.
If ticket issuance already happened, never add those tickets back to availability.
If refund/revocation returns inventory to saleable stock, require explicit policy decision and audit.
```

---

## 15. Payment-After-Expiry Inventory Rules

VS-00A owns the state-machine policy, but VS-00C must define the inventory side.

Required inventory outcomes:

| Case | Inventory outcome |
|---|---|
| Payment verified before hold expiry | Consume active hold. |
| Payment verified after hold expiry and inventory still available | Re-reserve/consume through ReservationLedger, then allow issuance. |
| Payment verified after hold expiry and inventory unavailable | Do not issue automatically. Move to manual_review/refund path. |
| Hold missing but order already ticket_issued | Idempotent success path; no inventory mutation. |
| Hold expired, release already returned inventory, payment later arrives | Apply re-reserve or manual_review rule. |
| Duplicate verified payment event | Do not change inventory twice. |

Forbidden behavior:

```text
Do not issue tickets after hold expiry without either consuming a valid hold or successfully re-reserving inventory.
Do not decrement availability twice for the same order.
Do not use payment success alone as inventory authority.
```

---

## 16. Cache, TTL, and PubSub Policy

The cache policy must define hot/warm/cold layers and invalidation.

### Required cache layers

```text
Hot active holds:
  Redis hashes + zsets
  TTL/expiry ledger based on checkout policy

Hot active availability:
  Redis integer/hash counter
  no Postgres hot reads during checkout

Active offer display:
  Cachex 1–5 minutes

Warm event offers:
  Redis sales:event:{event_id}:offers
  TTL 30 minutes

Payment/webhook dedupe:
  Redis SETNX-style key
  TTL 24 hours minimum

Conversation hot state:
  Redis hash/session key
  TTL based on WhatsApp session policy
```

### Invalidation triggers

```text
TicketOffer create/update/disable/archive -> invalidate event offer cache and broadcast PubSub update.
Inventory reserve/consume/release/expire -> update hot availability and broadcast offer availability if needed.
Order paid/issued/cancelled/refunded -> invalidate order/admin dashboard cache.
TicketIssue revoked/refunded -> enqueue sync aggregation and invalidate ticket delivery cache.
Reconciliation repair -> broadcast corrected availability and mark operational event.
```

### PubSub rules

```text
Use Phoenix PubSub / LiveView push updates for real-time availability updates.
Do not poll availability from LiveView during peak traffic.
Broadcast bounded summary events, not large payloads.
Do not broadcast PII.
```

---

## 17. Performance and Scaling Review

The inventory contract must answer these questions before later implementation begins:

```text
What inventory data is hot, warm, or cold?
Can checkout reserve/consume/release run without Postgres hot-path reads?
Are Redis operations bounded and atomic?
Is this safe under 100k concurrent users?
Does this trigger excess DB calls?
Is there a Redis-side representation for every high-velocity inventory operation?
Can availability updates be pushed instead of polled?
Can expiry be processed in bounded batches?
Can reconciliation be run without large table scans during peak?
What indexes are required on CheckoutSession, Order, OrderLine, and TicketIssue for reconciliation?
```

Required target behavior:

```text
Sub-100ms inventory operation target under normal load.
No overselling during spikes.
No ticket issuance without inventory authority.
No large Postgres scans during peak checkout.
Horizontal scalability across Phoenix nodes.
```

---

## 18. Required Future DB Index Notes

This planning slice must list the DB indexes that future slices need for expiry/reconciliation. It does not create them.

Required future indexes:

```text
sales_ticket_offers(event_id, sales_enabled, starts_at, ends_at)
sales_orders(event_id, status, inserted_at)
sales_orders(expires_at, status)
sales_order_lines(sales_order_id)
sales_order_lines(ticket_offer_id)
sales_checkout_sessions(status, expires_at)
sales_checkout_sessions(sales_order_id, status)
sales_ticket_issues(sales_order_id)
sales_ticket_issues(status)
sales_ticket_issues(scanner_status)
sales_state_transitions(entity_type, entity_id, inserted_at)
```

If tenanting is accepted:

```text
Add organization_id to relevant composite indexes and policy filters.
```

---

## 19. Required RED / GREEN Documentation Tests

These are documentation-contract checks. They can be manual checklists, markdown contract tests, or repo documentation lint checks.

### RED checks

The slice must fail review if any of these are true:

```text
No Redis key structure document exists.
No reserve/consume/release/expire operation contract exists.
No idempotency model exists.
No Redis unavailable behavior exists.
No Redis restart recovery behavior exists.
No Redis/Postgres reconciliation formula exists.
No payment-after-expiry inventory behavior exists.
No cache invalidation/PubSub policy exists.
Any sales channel can bypass ReservationLedger.
Ash resources are allowed to run Redis Lua.
Controllers/LiveViews/WhatsApp handlers are allowed to mutate reservation keys directly.
Release can double-increment availability.
Consume can double-decrement availability.
Expiry can release consumed holds.
Redis health is ignored during checkout.
No future concurrency tests are specified.
Implementation code is added in this slice.
```

### GREEN checks

The slice passes only if all of these are true:

```text
All required inventory docs exist.
The authority model clearly separates Redis hot state from Postgres/Ash durable state.
Every Redis key has type, purpose, owner, TTL/expiry behavior, and mutation rules.
ReservationLedger operations are fully specified.
Reserve, consume, release, expire, get_availability, and reconcile_offer have preconditions and outcomes.
Idempotency behavior is defined for duplicate reserve/consume/release/expiry/reconcile.
Redis failure and restart recovery behavior is documented.
Redis/Postgres reconciliation formula and report shape are documented.
Payment-after-expiry inventory outcomes are documented.
Cache TTL and PubSub invalidation rules are documented.
Future implementation tests cover concurrency, duplicate execution, Redis failure, expiry, and reconciliation.
No implementation code is added.
```

---

## 20. Future RED / GREEN Implementation Test Expectations

These tests are not implemented in VS-00C. They must be documented for VS-04A, VS-04B, VS-04C, VS-05, and VS-14.

### Future RED tests

```text
reserve fails when Redis inventory is unhealthy.
reserve fails when quantity exceeds availability.
reserve fails when quantity exceeds max_per_order.
duplicate reserve with same idempotency key does not decrement twice.
duplicate reserve with conflicting quantity returns conflict/manual_review_required.
consume fails or manual-reviews when hold is missing and no late-payment recovery exists.
duplicate consume does not consume twice.
release does not increment availability twice.
expiry does not release consumed holds.
expiry can safely retry after partial failure.
reconciliation refuses to reopen sales when ambiguous holds exist.
checkout does not continue when Redis unavailable.
WhatsApp checkout cannot bypass ReservationLedger.
web checkout cannot bypass ReservationLedger.
admin-assisted checkout cannot bypass ReservationLedger unless documented manual override exists.
```

### Future GREEN tests

```text
reserve creates hold, decrements availability, and records expiry.
consume marks hold consumed and prevents expiry release.
release returns availability exactly once.
expire_due_holds releases only active expired holds.
get_availability returns health and available count.
reconcile_offer adjusts safe drift and reports anomalies.
payment verified after expiry re-reserves if inventory exists.
payment verified after expiry manual-reviews if inventory is unavailable.
PubSub broadcast fires on reserve/consume/release/expire/reconcile repair.
Cache invalidation fires on offer update and inventory changes.
All operations are idempotent under duplicate Oban/job execution.
```

---

## 21. Acceptance Criteria

VS-00C is accepted only when:

```text
All required docs/artifacts are created.
Inventory authority model is explicit.
Redis key structure is explicit.
ReservationLedger operations are explicit.
Hold TTL and expiry policy is explicit.
Redis failure/recovery policy is explicit.
Redis/Postgres reconciliation policy is explicit.
Payment-after-expiry inventory behavior is explicit.
Cache, TTL, and PubSub policies are explicit.
Performance/scaling review is included.
Future DB index notes are included.
RED/GREEN documentation tests are included.
Future RED/GREEN implementation expectations are included.
No implementation code is added.
```

---

## 22. Coding-Agent TOON Prompt

| Field | Content |
|---|---|
| Task | Create the VS-00C Inventory Recovery and Reconciliation Contract documentation pack. |
| Objective | Define the Redis/Postgres inventory authority model, ReservationLedger operation contracts, idempotency rules, hold TTLs, Redis failure recovery, reconciliation, cache/PubSub rules, and future RED/GREEN tests before any inventory implementation begins. |
| Output | Create docs under `docs/fastcheck_sales/inventory/` and `docs/fastcheck_sales/slices/VS-00C_INVENTORY_RECOVERY_AND_RECONCILIATION_CONTRACT.md`. Include a master contract, authority model, Redis key structure, operation contract, idempotency/locking policy, hold TTL/expiry policy, Redis failure/recovery policy, reconciliation policy, cache/PubSub policy, health/launch gates, and inventory test plan. |
| Note | Planning only. Do not implement Redis Lua, Elixir modules, Ash resources, migrations, Oban workers, checkout logic, Paystack logic, WhatsApp logic, or UI. All channels are interfaces. WhatsApp is first, but web/admin/internal paths are supported and must use the same ReservationLedger. No Ash resource, controller, LiveView, or WhatsApp handler may mutate Redis inventory directly. Required Redis structures: hashes for offer/hold metadata, zsets for hold expiry, short lock keys for per-order locking, optional list/stream-like audit trail, warm event-offer cache, and optional future seat bitmap keys. Define TTLs, indexes needed later, invalidation triggers, PubSub broadcasting rules, Redis health gates, recovery behavior, and reconciliation report shape. |

---

## 23. Copy-Paste Prompt for Coding Agent

```text
You are working in the FastCheck Sales project.

Create the VS-00C Inventory Recovery and Reconciliation Contract documentation pack.

This is a planning-only slice. Do not write Elixir code. Do not add Ash resources. Do not add migrations. Do not write Redis Lua. Do not implement checkout, Paystack, WhatsApp, Oban workers, admin UI, or scanner changes.

Use these source documents as the authority:
- docs/fastcheck_sales/SOURCE_DOCS/FastCheck_Sales_Ash_Atlas_Planning_Pack_v0.2.3_HARDENED.md
- docs/fastcheck_sales/SOURCE_DOCS/FastCheck_Sales_Vertical_Slice_Roadmap_v1.1.3_HARDENED.md

Create or update these docs, following existing repo docs conventions if present:
- docs/fastcheck_sales/slices/VS-00C_INVENTORY_RECOVERY_AND_RECONCILIATION_CONTRACT.md
- docs/fastcheck_sales/inventory/INVENTORY_MASTER_CONTRACT.md
- docs/fastcheck_sales/inventory/INVENTORY_AUTHORITY_MODEL.md
- docs/fastcheck_sales/inventory/REDIS_KEY_STRUCTURE.md
- docs/fastcheck_sales/inventory/RESERVATION_LEDGER_OPERATION_CONTRACT.md
- docs/fastcheck_sales/inventory/INVENTORY_IDEMPOTENCY_AND_LOCKING.md
- docs/fastcheck_sales/inventory/HOLD_TTL_AND_EXPIRY_POLICY.md
- docs/fastcheck_sales/inventory/REDIS_FAILURE_AND_RECOVERY_POLICY.md
- docs/fastcheck_sales/inventory/REDIS_POSTGRES_RECONCILIATION_POLICY.md
- docs/fastcheck_sales/inventory/INVENTORY_CACHE_AND_PUBSUB_POLICY.md
- docs/fastcheck_sales/inventory/INVENTORY_HEALTH_AND_LAUNCH_GATES.md
- docs/fastcheck_sales/inventory/INVENTORY_TEST_PLAN.md

Required product framing:
- FastCheck Sales is multi-channel, but WhatsApp is first.
- Primary production customer channel is WhatsApp via Meta Cloud API.
- Secondary supported paths are admin-assisted sales, web checkout sales, and internal pilot sales.
- Every channel must use the same Sales core.
- No channel may bypass Redis inventory reservation, Paystack verification, idempotent ticket issuance, DeliveryAttempt audit, or scanner-safe revocation.

Required inventory rules:
- Redis owns hot operational inventory state during active sales.
- Postgres/Ash owns durable sales intent and recovery source data.
- All inventory mutations must go through FastCheck.Sales.Inventory.ReservationLedger.
- Ash resources must not run Redis Lua or mutate Redis directly.
- Controllers, LiveViews, WhatsApp handlers, and admin flows must not mutate reservation keys directly.

Required ReservationLedger operations to document:
- initialize_offer(offer_id, configured_quantity, version, metadata)
- reserve(offer_id, order_public_reference, quantity, ttl_seconds, idempotency_key)
- consume(offer_id, order_public_reference, quantity, idempotency_key)
- release(offer_id, order_public_reference, idempotency_key)
- expire_due_holds(now)
- get_availability(offer_id)
- mark_offer_health(offer_id, health_state, reason)
- reconcile_offer(offer_id)

Required Redis structures:
- sales:offer:{offer_id}:meta — hash
- sales:offer:{offer_id}:available — string integer or hash field
- sales:offer:{offer_id}:holds — zset expiry ledger
- sales:hold:{public_reference} — hash hold detail
- sales:order:{public_reference}:lock — short lock key
- sales:inventory:events:{offer_id} — optional list/stream-like audit trail
- sales:inventory:health:{offer_id} — health state
- sales:event:{event_id}:offers — warm display cache, TTL 30m

Also reserve future seat-specific patterns without implementing them:
- sales:seatmap:{event_id}:{offer_id} — Redis hash
- sales:seatbits:{event_id}:{offer_id} — Redis bitmap with SETBIT pattern
- sales:seat_holds:{event_id}:{offer_id} — zset hold expiry

Required RED/GREEN documentation tests:
RED if:
- no Redis key structure exists
- no reserve/consume/release/expire contract exists
- no idempotency model exists
- Redis failure/restart recovery is undefined
- Redis/Postgres reconciliation formula is undefined
- any channel can bypass ReservationLedger
- Ash resources/controllers/LiveViews/WhatsApp handlers can mutate Redis directly
- expiry can release consumed holds
- release can double-increment availability
- consume can double-decrement availability
- implementation code is added

GREEN if:
- all required docs exist
- authority model is explicit
- every Redis key has type, purpose, owner, TTL/expiry behavior, and mutation rules
- ReservationLedger operations have preconditions, outcomes, idempotency, and error behavior
- Redis failure and restart recovery are documented
- reconciliation formula and report shape are documented
- payment-after-expiry inventory outcomes are documented
- cache TTL and PubSub invalidation rules are documented
- future tests cover concurrency, duplicate execution, Redis failure, expiry, and reconciliation
- no implementation code is added

Acceptance criteria:
- All required documentation artifacts exist.
- No code/migrations/resources/scripts/workers are added.
- Inventory safety is channel-independent.
- Future coding agents cannot reasonably build an unsafe inventory hot path from missing rules.
```

---

## 24. Human Review Checklist

Before marking VS-00C done, confirm:

```text
No channel can bypass ReservationLedger.
No Ash resource can mutate Redis inventory.
No controller, LiveView, or WhatsApp handler can mutate Redis inventory directly.
Reserve is specified as atomic and idempotent.
Consume is specified as idempotent and cannot double-decrement.
Release is specified as idempotent and cannot double-increment.
Expiry cannot release consumed holds.
Redis unavailable behavior closes/degrades checkout safely.
Redis restart recovery does not reopen sales before reconciliation.
Reconciliation formula is deterministic.
Reconciliation report shape is explicit.
Payment-after-expiry inventory behavior is explicit.
Cache TTL and PubSub invalidation rules are explicit.
Future concurrency/load tests are specified.
No implementation code was added.
```

---

## 25. Success Definition

VS-00C succeeds when future coding agents cannot reasonably invent unsafe behavior for:

```text
Redis reserve/consume/release
hold expiry
duplicate worker execution
Redis outage
Redis restart recovery
Redis/Postgres reconciliation
payment after hold expiry
availability display caching
PubSub updates
WhatsApp/web/admin inventory entrypoints
```

The correct understanding must be:

```text
Redis is the hot inventory ledger.
Postgres/Ash is durable business truth and recovery source.
ReservationLedger is the only inventory mutation boundary.
All channels share the same inventory safety rules.
No sale continues when inventory health is unknown.
No ticket issuance happens without inventory authority.
```
