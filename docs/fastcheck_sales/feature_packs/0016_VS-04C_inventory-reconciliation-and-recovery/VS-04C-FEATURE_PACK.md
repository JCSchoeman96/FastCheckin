# FastCheck Sales Feature Planning Pack — VS-04C Inventory Reconciliation and Recovery

**Pack ID:** `0016_VS-04C_inventory-reconciliation-and-recovery`  
**Repository path:** `docs/fastcheck_sales/feature_packs/0016_VS-04C_inventory-reconciliation-and-recovery`  
**Slice:** `VS-04C`  
**Slice name:** Inventory Reconciliation and Recovery  
**Version:** `v1.0`  
**Date:** 2026-06-12  
**Status:** Implementation planning pack — implementation blocked until VS-05 checkout/order states exist  
**Primary area:** Redis / Postgres / Oban / Inventory Recovery / QA  
**Depends on:** VS-00A, VS-00B, VS-00C, VS-00D, VS-01B, VS-01C, VS-01D, VS-01G, VS-03, VS-04A, VS-04B, VS-05  
**Blocks:** VS-14 hardening, VS-22 launch E2E, production launch readiness  
**Source docs:**

```text
docs/fastcheck_sales/SOURCE_DOCS/FastCheck_Sales_Ash_Atlas_Planning_Pack_v0.2.3_HARDENED.md
docs/fastcheck_sales/SOURCE_DOCS/FastCheck_Sales_Vertical_Slice_Roadmap_v1.1.3_HARDENED.md
```

---

## 1. Purpose

This pack instructs a coding agent to implement the **Redis/Postgres inventory reconciliation and recovery layer** for FastCheck Sales.

VS-04B built the hot atomic Redis inventory ledger. VS-04C adds the tooling that proves the system can recover when Redis and durable Sales state drift.

This slice is not a checkout feature. It is a safety feature.

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

The reconciliation layer must not sell tickets, issue tickets, verify payments, or mutate scanner state directly. It must detect inventory drift, repair safe cases, fail closed on unsafe cases, and surface manual-review signals where automated repair would risk overselling.

---

## 2. Ultimate Outcome

After VS-04C is complete:

```text
Redis inventory health can be checked per offer.
Redis hot inventory can be compared against durable Sales/Postgres state.
Redis restart/loss can be detected.
Safe Redis rebuild from durable state is possible.
Unsafe drift moves to fail-closed/manual-review behavior.
Reconciliation never oversells.
Reconciliation never releases consumed inventory.
Reconciliation never treats unpaid/expired orders as sold inventory.
Reconciliation accounts for paid, issued, held, expired, released, cancelled, and refunded states according to VS-00A/VS-05.
Reconciliation tooling is idempotent.
Reconciliation has Oban/manual entrypoints as appropriate.
Tests prove recovery behavior after simulated Redis loss and drift.
No checkout, payment, ticket issuance, WhatsApp, or scanner hot-path behavior is added.
```

The result should give confidence that a Redis outage or stale key set does not corrupt sales inventory.

---

## 3. Scope

### In scope

```text
Create or update FastCheck.Sales.Inventory.Reconciler.
Create or update FastCheck.Sales.Inventory.Recovery.
Create or update FastCheck.Sales.Inventory.Health.
Create or update an Oban worker for scheduled/manual inventory reconciliation if the project uses Oban.
Add explicit reconciliation result structs or tagged tuples.
Compare Redis inventory state against durable Sales resources/tables.
Detect missing Redis offer keys.
Detect Redis available count drift.
Detect stale held holds.
Detect consumed holds that must not be released.
Detect durable paid/issued/cancelled/refunded effects.
Rebuild Redis offer inventory from durable state when safe.
Fail closed when durable state is insufficient or ambiguous.
Record reconciliation events through logs/telemetry without PII.
Add tests for Redis loss, stale holds, duplicate recovery runs, and unsafe drift.
Add RED/GREEN tests before or alongside implementation.
```

### Out of scope

```text
No checkout session workflow implementation.
No Order state-machine implementation beyond read-only durable-state queries required for reconciliation.
No PaymentAttempt or Paystack implementation.
No webhook behavior.
No WhatsApp or Meta API behavior.
No ticket issuing.
No Attendee creation.
No scanner hot-path changes.
No LiveView/admin UI.
No manual refund/revocation UI.
No changing legal state matrices.
No changing VS-04B reserve/consume/release public API unless the tests prove a bug in the implementation and the contract remains backward compatible.
No Ash resource actions that directly mutate Redis.
```

---

## 4. Critical Dependency Warning

This pack can be created now, but implementation must not start until VS-05 is accepted.

Reason:

```text
Inventory reconciliation needs real Order and CheckoutSession states.
Without VS-05, the agent would be forced to invent state semantics, which is forbidden.
```

Required accepted inputs:

```text
VS-00A State Machine and Failure Policy Finalization
VS-00B Security, PII, and Token Policy Finalization
VS-00C Inventory Recovery and Reconciliation Contract
VS-00D MVP Purchase Entry-Point and Launch Scope Decision
VS-03 Ticket Offer Management
VS-04A Inventory Ledger Contract Finalization
VS-04B Atomic Inventory Ledger Implementation
VS-05 Order and Checkout Core
```

If VS-05 is not present, the agent may only prepare documentation tests and stubs that fail clearly.

---

## 5. Required Discovery Step

Before changing code, the agent must locate and document actual repository paths for:

```text
FastCheck.Sales.Inventory.ReservationLedger
FastCheck.Sales.Inventory.RedisScripts
existing Redis connection/pool wrapper
existing Oban worker conventions
existing telemetry conventions
existing logger metadata conventions
TicketOffer Ash resource
Order Ash resource
CheckoutSession Ash resource
TicketIssue Ash resource if created
Sales domain module
existing test helpers for Redis and Oban
existing async test limitations around Redis
existing clock/time helper conventions
```

If the repository already has a health-check or reconciliation pattern, follow it. Do not create a second style without a strong reason.

---

## 6. Domain and Boundary Details

### Ash domain referenced

```text
FastCheck.Sales
```

### Ash resources read by reconciliation

```text
FastCheck.Sales.TicketOffer
FastCheck.Sales.Order
FastCheck.Sales.OrderLine
FastCheck.Sales.CheckoutSession
FastCheck.Sales.TicketIssue
FastCheck.Sales.StateTransition
```

### Ash resources not created by this slice

```text
No new Ash resource is required by default.
```

Optional later resource:

```text
FastCheck.Sales.InventorySnapshot
```

Do not create `InventorySnapshot` in this slice unless the architecture lead explicitly approves it. Reconciliation can initially report through return values, logs, telemetry, and tests.

### Plain Elixir modules to create/update

Preferred paths:

```text
lib/fastcheck/sales/inventory/health.ex
lib/fastcheck/sales/inventory/reconciler.ex
lib/fastcheck/sales/inventory/recovery.ex
```

Optional worker path:

```text
lib/fastcheck/workers/inventory_reconciliation_worker.ex
```

Preferred test paths:

```text
test/fastcheck/sales/inventory/health_test.exs
test/fastcheck/sales/inventory/reconciler_test.exs
test/fastcheck/sales/inventory/recovery_test.exs
test/fastcheck/sales/inventory/reconciliation_worker_test.exs
test/fastcheck/sales/inventory/reconciliation_boundary_test.exs
```

---

## 7. Required Public API Contract

The exact function names may follow project conventions, but the implementation must expose these capabilities through a small, documented API.

### Health API

```elixir
offer_health(offer_id)
```

Required behavior:

```text
Returns whether Redis has the required inventory keys for the offer.
Returns configured inventory, Redis availability, active holds, stale holds, and drift indicators where possible.
Does not repair by default.
Does not mutate Redis.
Does not query large tables without indexes.
```

Preferred return shape:

```elixir
{:ok, %HealthReport{}}
{:error, reason}
```

### Reconciliation API

```elixir
reconcile_offer(offer_id, opts \\ [])
```

Required behavior:

```text
Compares Redis hot state to durable Sales/Postgres state.
Detects safe repair actions.
Detects unsafe drift.
Can run in dry-run mode.
Is idempotent.
Never oversells.
Never releases consumed holds.
Never repairs ambiguous state automatically.
```

Preferred return shape:

```elixir
{:ok, %ReconciliationReport{}}
{:manual_review_required, %ReconciliationReport{}}
{:error, reason}
```

### Recovery API

```elixir
rebuild_offer_inventory(offer_id, opts \\ [])
```

Required behavior:

```text
Rebuilds Redis inventory keys from durable state when safe.
Defaults to fail-closed if durable state cannot determine availability.
Supports dry-run mode.
Requires explicit allow_repair: true or similar for mutating repair.
Uses ReservationLedger or approved RedisScripts only.
```

Preferred return shape:

```elixir
{:ok, %RecoveryReport{}}
{:manual_review_required, %RecoveryReport{}}
{:error, reason}
```

### Expired hold repair API

```elixir
repair_stale_holds(offer_id, now, opts \\ [])
```

Required behavior:

```text
Detects expired held holds.
Does not release consumed holds.
Does not release holds for paid/verified orders unless legal state policy says it is safe.
Uses the same expiry semantics as ReservationLedger.expire_due_holds/1.
```

---

## 8. Redis Structures Referenced

VS-04C must use the Redis structures from VS-04B.

```text
sales:offer:{offer_id}:inventory              # hash
sales:offer:{offer_id}:holds                  # zset expiry ledger
sales:hold:{public_reference}                 # hash hold detail
sales:order:{public_reference}:lock           # short-lived SET NX PX key
sales:inventory:dedupe:{operation}:{key}      # idempotency/dedupe
sales:inventory:events:{offer_id}             # list/stream-like audit trail if implemented
```

Rules:

```text
Do not create a competing key structure.
Do not store buyer name, phone, email, Paystack payloads, Meta payloads, QR tokens, or delivery tokens in inventory keys.
Use Redis keys only for operational IDs and counts.
```

---

## 9. Durable State Inputs

Reconciliation must use indexed queries over durable Sales state.

### TicketOffer inputs

```text
offer id
event_id
configured_quantity_available
initial_quantity
sales_enabled
archived_at
```

### CheckoutSession inputs

```text
sales_order_id
status
redis_hold_key
hold_quantity
expires_at
released_at
expired_at
```

### Order inputs

```text
id
public_reference
event_id
status
expires_at
paid_at
cancelled_at
expired_at
refunded_at
```

### OrderLine inputs

```text
sales_order_id
ticket_offer_id
quantity
```

### TicketIssue inputs

```text
sales_order_id
sales_order_line_id
status
scanner_status
revoked_at
```

### StateTransition inputs

```text
entity_type
entity_id
from_state
to_state
inserted_at
reason
metadata
```

Use `StateTransition` only for audit/recovery explanation. Do not rely on it as the primary truth when current status fields are authoritative.

---

## 10. Reconciliation Rules

### 10.1 Source-of-truth hierarchy

```text
Postgres/Ash durable records are the source of durable business truth.
Redis is the hot operational ledger.
Redis must be rebuilt or repaired from durable state when safe.
If durable state is ambiguous, fail closed and require manual review.
```

### 10.2 Sold/consumed count

Count inventory as sold/consumed only when durable state proves value delivery or unavoidable payment obligation.

Typical sold/consumed durable states:

```text
Order.status in paid_verified, fulfillment_queued, ticket_issued, partially_issued
TicketIssue.status in issued, revoked if the ticket was previously issued and must not return inventory automatically
```

Rules:

```text
Refunded/revoked does not automatically return inventory unless the approved refund/revocation policy says resale is allowed.
Cancelled unpaid orders do not count as sold.
Expired unpaid orders do not count as sold.
Manual review orders must be handled conservatively.
```

### 10.3 Held count

Count inventory as held only when:

```text
CheckoutSession.status indicates an active hold.
Order is not cancelled/refunded/expired.
Hold has not expired unless late-payment policy says it must remain protected.
Redis hold key still maps to that order/reference or can be reconstructed safely.
```

### 10.4 Available count

Preferred calculation:

```text
available = configured_quantity_available - sold_count - active_hold_count
```

Rules:

```text
available must never be negative.
If calculated available is negative, fail closed and require manual review.
If Redis available is greater than calculated safe available, reconcile Redis downward.
If Redis available is lower than calculated safe available, reconcile upward only if no ambiguity exists.
```

### 10.5 Manual-review cases

Manual review is required when:

```text
A verified payment exists for an expired/missing hold and inventory is unavailable.
Durable state says paid/issued but Redis has no corresponding consumed/held history.
Calculated available is negative.
Multiple durable states conflict.
Redis holds reference unknown orders.
Redis consumed history conflicts with TicketIssue/Order state.
Repair would require guessing customer/payment intent.
```

---

## 11. Recovery Rules

### Redis unavailable

```text
Do not accept new reservations.
Do not silently fall back to Postgres live counters.
Health API returns degraded/unavailable.
Checkout must fail closed once VS-05/VS-14 consume this behavior.
```

### Redis restart/loss

```text
Detect missing offer inventory keys.
Rebuild Redis from durable state only when safe.
Keep sales closed/fail-closed until the rebuild completes or manual review resolves ambiguity.
```

### Stale holds

```text
Expired unpaid holds may be released.
Consumed holds must never be released.
Late-payment holds must follow VS-00A/VS-05 payment-after-expiry policy.
```

### Duplicate recovery runs

```text
Reconciliation and rebuild operations must be idempotent.
Two workers running the same offer reconciliation must not double-release, double-consume, or corrupt availability.
Use short Redis locks or DB/advisory locks according to project convention.
```

### Worker failure mid-repair

```text
Partial repair must be safe to retry.
Report must show what was planned, what was applied, and what still requires review.
Do not leave Redis with availability above safe calculated availability.
```

---

## 12. Worker Contract

If an Oban worker is implemented, use this contract.

Preferred worker:

```text
FastCheck.Workers.InventoryReconciliationWorker
```

Queue:

```text
sales_inventory
```

Uniqueness:

```text
by offer_id and reconciliation window/purpose
```

Arguments:

```text
offer_id
mode: health_check | dry_run | repair
trigger: scheduled | startup | manual | post_failure
correlation_id
```

Rules:

```text
Worker must load fresh durable state before every repair.
Worker must default to dry_run unless explicitly scheduled/allowed for repair.
Worker must be idempotent.
Worker must not perform checkout/payment/ticket issuance.
Worker must log summaries without PII.
Worker must emit telemetry.
```

---

## 13. Telemetry and Logging

Required telemetry events:

```text
[:fastcheck, :sales, :inventory, :health_checked]
[:fastcheck, :sales, :inventory, :reconcile_started]
[:fastcheck, :sales, :inventory, :reconciled]
[:fastcheck, :sales, :inventory, :reconciliation_failed]
[:fastcheck, :sales, :inventory, :manual_review_required]
[:fastcheck, :sales, :inventory, :rebuild_started]
[:fastcheck, :sales, :inventory, :rebuilt]
```

Allowed metadata:

```text
offer_id
event_id
correlation_id
mode
trigger
safe_available
redis_available
sold_count
active_hold_count
manual_review_required
```

Forbidden metadata/log data:

```text
buyer_name
buyer_phone
buyer_email
Paystack payloads
Meta payloads
QR tokens
delivery tokens
authorization_url
access_code
raw webhook payloads
```

---

## 14. Performance and Scaling Review

### Data layers

```text
Hot data: Redis inventory keys and hold zsets.
Warm data: Cachex/Redis active offer display caches.
Cold durable data: Postgres/Ash Sales tables.
```

### Performance rules

```text
Do not run reconciliation on every checkout request.
Do not scan all orders for every offer without indexed filters.
Do not run large table scans during peak sales.
Use offer-scoped queries.
Use indexed status/expires_at/order_line paths.
Use worker/dry-run recovery outside the hot checkout path.
Use pagination or streaming for large recovery reports.
```

### Required indexes from earlier slices

```text
sales_order_lines(ticket_offer_id)
sales_order_lines(sales_order_id)
sales_orders(event_id, status, inserted_at)
sales_orders(expires_at, status)
sales_checkout_sessions(status, expires_at)
sales_checkout_sessions(sales_order_id, status)
sales_ticket_issues(sales_order_id)
sales_ticket_issues(status)
sales_state_transitions(entity_type, entity_id, inserted_at)
```

No reconciliation query should require a sequential scan on large Sales tables during launch-readiness testing.

---

## 15. Security Review

This slice must preserve VS-00B rules.

```text
No PII in Redis inventory keys.
No tokens in Redis inventory keys.
No Paystack/Meta raw payloads in inventory logs.
No customer contact details in telemetry metadata.
No broad customer-session access to reconciliation reports.
Operator access to reconciliation reports must be summarized and non-sensitive.
Admin access may show operational detail, but still not raw provider payloads.
```

---

## 16. RED/GREEN Test Plan

The coding agent must write or update tests so they fail before implementation and pass after implementation.

### RED tests must fail when

```text
Inventory health API is missing.
Reconciler module is missing.
Recovery module is missing.
Reconciliation accepts Redis state as truth over durable Sales state.
Redis rebuild proceeds when durable state is ambiguous.
Rebuild sets available above safe calculated availability.
Expired consumed holds are released.
Duplicate reconciliation runs corrupt availability.
Redis unavailable allows new reservations through fallback logic.
Manual-review cases are auto-repaired.
Reconciliation queries are not scoped to offer/event.
Logs or telemetry include PII/tokens/provider payloads.
Oban worker runs without uniqueness/idempotency protection.
Ash resources directly mutate inventory keys.
```

### GREEN tests must prove

```text
offer_health/1 reports healthy Redis inventory.
offer_health/1 reports missing Redis keys after simulated Redis loss.
reconcile_offer/2 dry-run reports drift without mutating Redis.
reconcile_offer/2 safely reconciles Redis available downward when Redis overstates availability.
reconcile_offer/2 safely reconciles Redis available upward only when durable state is unambiguous.
rebuild_offer_inventory/2 rebuilds Redis from durable state after simulated Redis key loss.
repair_stale_holds/3 releases only expired unpaid holds.
repair_stale_holds/3 does not release consumed holds.
verified late-payment with unavailable inventory moves to manual-review result.
manual_review_required is returned for ambiguous/conflicting state.
duplicate worker/reconcile execution is idempotent.
Redis unavailable produces degraded/fail-closed result.
telemetry events are emitted with safe metadata.
logs do not include PII, tokens, Paystack payloads, or Meta payloads.
only approved inventory modules mutate inventory Redis keys.
```

### Suggested test files

```text
test/fastcheck/sales/inventory/health_test.exs
test/fastcheck/sales/inventory/reconciler_test.exs
test/fastcheck/sales/inventory/recovery_test.exs
test/fastcheck/sales/inventory/reconciliation_worker_test.exs
test/fastcheck/sales/inventory/reconciliation_boundary_test.exs
```

---

## 17. Acceptance Criteria

This pack is accepted only when:

```text
Inventory health API exists and is tested.
Reconciliation API exists and is tested.
Recovery/rebuild API exists and is tested.
Dry-run reconciliation works.
Safe repair mode requires explicit opt-in.
Redis loss can be simulated and safely rebuilt when durable state is unambiguous.
Ambiguous durable state returns manual_review_required and does not auto-repair.
Redis unavailable fails closed.
Duplicate reconciliation runs are safe.
No checkout/payment/ticket/WhatsApp/scanner behavior was added.
No Ash resource directly mutates Redis inventory keys.
Telemetry/logging use safe metadata only.
Performance review confirms indexed offer-scoped queries.
RED/GREEN tests are present and meaningful.
```

---

## 18. Avoid

```text
Do not use Postgres as a hot checkout counter.
Do not run reconciliation inside the checkout request path.
Do not trust Redis over durable paid/issued/refunded state.
Do not auto-repair ambiguous payment/order/ticket states.
Do not release consumed holds.
Do not make refunded/revoked tickets automatically resellable unless policy explicitly allows it.
Do not add provider HTTP calls.
Do not add WhatsApp flow logic.
Do not issue tickets.
Do not modify scanner hot path.
Do not expose raw reconciliation internals to customer_session actors.
```

---

## 19. TOON Coding-Agent Prompt

| Field | Content |
|---|---|
| Task | Implement inventory reconciliation and recovery tooling for FastCheck Sales. |
| Objective | Make Redis inventory recoverable from durable Sales state without overselling, corrupting holds, or inventing checkout/payment behavior. |
| Output | Create/update `lib/fastcheck/sales/inventory/health.ex`, `lib/fastcheck/sales/inventory/reconciler.ex`, `lib/fastcheck/sales/inventory/recovery.ex`, optionally `lib/fastcheck/workers/inventory_reconciliation_worker.ex`, and tests under `test/fastcheck/sales/inventory/`. |
| Note | Implementation is blocked until VS-05 checkout/order states exist. Use offer-scoped indexed durable queries. Redis is hot operational state; Postgres/Ash is durable business truth. Rebuild Redis only when safe and explicit repair mode is enabled. Ambiguous state must return `manual_review_required`. Do not implement checkout, payment, ticket issuance, WhatsApp, admin UI, or scanner logic. Do not mutate Redis from Ash resources. Do not log PII, Paystack payloads, Meta payloads, QR tokens, delivery tokens, authorization URLs, or access codes. Emit safe telemetry. Tests must prove Redis loss recovery, stale hold repair, fail-closed Redis unavailable behavior, idempotent duplicate runs, no consumed-hold release, and no oversell after repair. |

---

## 20. Copy-Paste Prompt for Coding Agent

```text
You are implementing FastCheck Sales slice VS-04C — Inventory Reconciliation and Recovery.

Read these source docs first:
- docs/fastcheck_sales/SOURCE_DOCS/FastCheck_Sales_Ash_Atlas_Planning_Pack_v0.2.3_HARDENED.md
- docs/fastcheck_sales/SOURCE_DOCS/FastCheck_Sales_Vertical_Slice_Roadmap_v1.1.3_HARDENED.md
- Feature pack: 0016_VS-04C_inventory-reconciliation-and-recovery/FEATURE_PACK.md

Goal:
Implement inventory health, reconciliation, and recovery tooling that compares Redis hot inventory state against durable Sales/Postgres state and repairs only safe drift.

Important dependency:
Do not implement this slice until VS-05 Order and Checkout Core exists. If VS-05 is absent, create only failing tests/stubs or report the block.

Implement only inside the approved inventory recovery boundary:
- lib/fastcheck/sales/inventory/health.ex
- lib/fastcheck/sales/inventory/reconciler.ex
- lib/fastcheck/sales/inventory/recovery.ex
- optional lib/fastcheck/workers/inventory_reconciliation_worker.ex
- tests under test/fastcheck/sales/inventory/

Required behavior:
- health checks detect healthy, missing, degraded, and drifted Redis inventory.
- dry-run reconciliation reports drift without mutation.
- explicit repair mode can rebuild Redis from durable state when safe.
- ambiguous state returns manual_review_required.
- Redis unavailable fails closed.
- consumed holds are never released.
- stale unpaid holds can be repaired according to the legal state policy.
- duplicate reconciliation/rebuild runs are idempotent.
- no checkout, payment, WhatsApp, ticket issuance, admin UI, or scanner behavior is added.
- no Ash resource directly mutates Redis.
- telemetry/logging contains no PII, tokens, provider payloads, authorization URLs, or access codes.

Write RED/GREEN tests first or alongside implementation. Tests must fail before implementation and pass after implementation.

Keep code minimal, explicit, and scalable. Do not over-engineer. Use existing Redis, Oban, telemetry, and test conventions from the repo.
```

---

## 21. Human Review Checklist

Before accepting this slice, verify:

```text
Implementation waited for VS-05 or clearly reports the block.
Health/Reconciler/Recovery APIs are small and explicit.
Dry-run and repair modes are separate.
Repair requires explicit opt-in.
Manual-review cases are not auto-repaired.
Redis unavailable fails closed.
Rebuild uses durable state and never trusts Redis over Postgres/Ash.
No consumed hold can be released by expiry/recovery.
Duplicate workers/runs are idempotent.
No checkout/payment/ticket/WhatsApp/scanner logic was added.
No Ash resource directly mutates Redis.
Queries are indexed and offer-scoped.
Telemetry/logging metadata is safe.
RED/GREEN tests prove Redis loss, drift repair, stale holds, duplicate run safety, fail-closed behavior, and PII/log safety.
```
