# FastCheck Sales Feature Planning Pack — VS-14 Checkout Expiry and Cleanup

**Pack ID:** `0034_VS-14_checkout-expiry-and-cleanup`  
**Slice:** `VS-14`  
**Slice name:** Checkout Expiry and Cleanup  
**Version:** `v1.0`  
**Date:** 2026-06-13  
**Status:** Implementation-ready cleanup/expiry slice  
**Primary area:** Checkout / Redis inventory holds / Oban cleanup / Payment-after-expiry safety  
**Repo truth:** `JCSchoeman96/FastCheckin`  
**Repository path:** `docs/fastcheck_sales/feature_packs/0034_VS-14_checkout-expiry-and-cleanup`  
**Source docs:**  
- `docs/fastcheck_sales/SOURCE_DOCS/FastCheck_Sales_Ash_Atlas_Planning_Pack_v0.2.3_HARDENED.md`  
- `docs/fastcheck_sales/SOURCE_DOCS/FastCheck_Sales_Vertical_Slice_Roadmap_v1.1.3_HARDENED.md`  
**Depends on:** VS-04B, VS-05, VS-06B, VS-07B, VS-07C, VS-09D, VS-10, VS-21A
**Blocks:** VS-15A, VS-15B, VS-18, VS-19, VS-22, VS-23B, VS-04C

---

## 1. Purpose

Implement the safe cleanup path for abandoned or expired checkout sessions.

The goal is not merely to mark old rows as expired. The goal is:

```text
unpaid checkout expires
  -> checkout state becomes expired
  -> held inventory is released exactly once through ReservationLedger
  -> stale payment link can no longer become an automatic fulfillment path
  -> late Paystack verification after expiry is routed to VS-07C policy/manual review
  -> dashboard/admin queues can see cleanup outcome
```

This slice closes a major oversell and stale-payment risk before WhatsApp payment flows are enabled.

---

## 2. FastCheckin Repo Truth

The current repo is `JCSchoeman96/FastCheckin`, module root `FastCheck`, app `:fastcheck`.

Current relevant runtime facts:

```text
FastCheck.Application supervises FastCheck.Redis.Connection, Oban, PubSub, Cache/EtsOwner, and the web endpoint.
config/config.exs currently configures Oban with repo FastCheck.Repo, queue scan_persistence: 10, and Oban.Plugins.Pruner.
FastCheck.Redis.Connection provides a supervised named Redix connection: FastCheck.Redix.
FastCheck.Scans.HotState.RedisStore shows the existing Redis design style: explicit keyspace modules, Lua for atomic state, build locks, idempotency TTLs, and fail-safe hot-state behavior.
FastCheck.Events.Event already has event_sync_version for mobile attendee/invalidation sync.
```

VS-14 must follow those existing patterns rather than inventing a parallel runtime style.

---

## 3. Ultimate Outcome

After VS-14:

```text
CheckoutSession rows that pass expires_at are expired by a scheduled Oban worker.
Each expired checkout releases Redis inventory holds once, using the VS-04B ReservationLedger only.
Checkout expiry is idempotent under duplicate worker runs.
PaymentAttempt state is not falsely converted to paid/failed by cleanup.
Late verified payments are routed to the VS-07C payment-after-expiry policy.
StateTransition audit rows show who/what expired the checkout and why.
The admin dashboard can list expired/manual-review checkout outcomes without scanning all orders.
```

---

## 4. Scope

### In scope

```text
Add scheduled checkout expiry worker(s).
Add explicit checkout expiration service boundary.
Expire eligible CheckoutSession rows.
Release Redis reservation holds via ReservationLedger.release/expire only.
Append StateTransition rows for expiry and release outcomes.
Classify late-payment-after-expiry cases using existing VS-07C policy states.
Invalidate only relevant Sales/admin cache entries.
Emit telemetry for expired, released, skipped, failed, and manual_review outcomes.
Add indexes for expiry scans and worker idempotency.
Add RED/GREEN tests for duplicate workers, Redis failures, late payments, and no fulfillment.
```

### Out of scope

```text
No ticket issuing.
No TicketIssue mutation.
No Attendee mutation.
No scanner/mobile sync changes.
No DeliveryAttempt creation.
No WhatsApp/Meta behavior.
No Paystack API calls.
No refund execution.
No customer-facing notification.
No broad scheduler dashboard.
No direct Redis key mutation outside ReservationLedger.
```

---

## 5. Recommended Files

Use repo naming consistent with FastCheckin:

```text
lib/fastcheck/sales/checkout_expiry.ex
lib/fastcheck/workers/checkout_expiry_worker.ex
lib/fastcheck/workers/checkout_expiry_sweeper_worker.ex
lib/fastcheck/sales/checkout_session.ex
lib/fastcheck/sales/order.ex
lib/fastcheck/sales/state_transition.ex
lib/fastcheck/sales/inventory/reservation_ledger.ex
priv/repo/migrations/*_add_checkout_expiry_indexes.exs
test/fastcheck/sales/checkout_expiry_test.exs
test/fastcheck/workers/checkout_expiry_worker_test.exs
test/fastcheck/workers/checkout_expiry_sweeper_worker_test.exs
```

Do not change `FastCheck.Attendees.Scan`, `FastCheckWeb.Mobile.SyncController`, or existing scanner hot-state modules in this slice.

---

## 6. Domain Model

### Main resources touched

```text
FastCheck.Sales.CheckoutSession
FastCheck.Sales.Order
FastCheck.Sales.OrderLine
FastCheck.Sales.PaymentAttempt
FastCheck.Sales.StateTransition
FastCheck.Sales.Inventory.ReservationLedger
```

### State concepts

CheckoutSession expected statuses:

```text
payment_link_sent
payment_started
expired
released
paid
manual_review
failed
cancelled
```

Order expected statuses relevant to cleanup:

```text
draft
awaiting_payment
payment_pending
paid_verified
manual_review
cancelled
expired
fulfillment_queued
```

PaymentAttempt relevant statuses:

```text
initialized
verification_pending
verified_success
failed
provider_pending
verified_amount_mismatch
verified_currency_mismatch
manual_review
```

Do not introduce generic `update_status`. Use named actions/transitions.

---

## 7. Expiry Eligibility Rules

A checkout is eligible for automatic expiry only when:

```text
CheckoutSession.expires_at <= now
CheckoutSession.status in [payment_link_sent, payment_started]
Order.status in [awaiting_payment, payment_pending]
No PaymentAttempt.status = verified_success exists for the order
No TicketIssue exists for the order
No Attendee bridge completion exists for the order
CheckoutSession.reservation_id or reservation reference exists when inventory was held
```

Skip and classify instead of expiring when:

```text
PaymentAttempt is verified_success -> route to VS-07C late-payment/expiry policy if checkout expired.
Order is paid_verified or fulfillment_queued -> do not release inventory here.
Order is already terminal -> idempotent no-op.
CheckoutSession is already expired/released -> idempotent no-op.
Inventory release fails due Redis outage -> keep retryable state, do not mark released.
ReservationLedger reports already released/expired -> mark idempotent released if durable state agrees.
```

---

## 8. Worker Design

### `CheckoutExpirySweeperWorker`

Purpose:

```text
Find expired checkout sessions in bounded batches and enqueue one CheckoutExpiryWorker per checkout_session_id.
```

Rules:

```text
Run on a dedicated Oban queue, e.g. `sales_maintenance`.
Use max_attempts and uniqueness to prevent duplicate floods.
Batch size configurable, default 100–500.
Query only indexed fields.
Never load unbounded expired sessions.
No Redis work inside the sweeper.
No state mutation inside the sweeper except optional heartbeat metrics.
```

### `CheckoutExpiryWorker`

Purpose:

```text
Expire one CheckoutSession and release its inventory reservation safely.
```

Rules:

```text
Use Oban uniqueness by checkout_session_id.
Use DB transaction for durable state transitions.
Do not hold DB transaction while doing slow external HTTP; there is no external HTTP in this worker.
Redis ReservationLedger operation may be inside or immediately before/after DB transaction according to VS-04B contract, but recovery must be deterministic.
Append StateTransition rows.
Emit telemetry.
```

---

## 9. Redis and Inventory Rules

VS-14 must use only the approved inventory boundary:

```text
FastCheck.Sales.Inventory.ReservationLedger.release/expire(...)
```

Do not call Redix directly from the worker except through the ReservationLedger if that is how VS-04B implemented it.

Expected Redis structures from prior slices:

```text
Seat/stock availability: Redis hash or counters per ticket offer/event.
Reservation holds: Redis ZSET keyed by expiration time.
Reservation idempotency: Redis key/hash/set with TTL.
Rate/queue protection: Redis zsets where needed.
```

VS-14-specific rules:

```text
Release must be idempotent by checkout_session_id / reservation_id.
Release must not increase inventory twice.
Release must update Redis operational ledger before durable released state is accepted, unless VS-04C defines a compensating recovery path.
If Redis is unavailable, fail closed: keep checkout in expiry_pending or equivalent retryable state and let Oban retry.
Never mark checkout released if inventory release is unknown.
```

---

## 10. Late Payment Safety

A late payment can arrive after checkout expiry through Paystack verification.

VS-14 does not verify payment and does not refund.

Required behavior:

```text
If payment is already verified_success before cleanup runs:
  - do not release inventory in VS-14
  - route to VS-07C policy/manual_review outcome

If cleanup expired/released the checkout and a payment is verified later:
  - VS-07C must classify as late_payment_expired_checkout
  - no automatic ticket issuance
  - no automatic Attendee creation
  - no automatic inventory consume
  - manual review/refund-required flow handles outcome later
```

Add tests that assert stale payment links cannot cause fulfillment after expiry.

---

## 11. Cache and PubSub Rules

Relevant FastCheckin cache patterns:

```text
FastCheck.Cache.CacheManager uses Cachex and configured TTLs.
FastCheck.Cache.EtsLayer caches scanner/event/attendee state.
Scanner/mobile sync caches must not be touched unless Attendee/scanner state changes, which VS-14 does not do.
```

VS-14 cache rules:

```text
Invalidate Sales checkout/order/admin dashboard caches only.
Do not invalidate attendee ETS caches.
Do not bump event_sync_version.
Do not publish scanner/mobile sync events.
Optionally PubSub broadcast internal sales-dashboard queue changes: sales:admin:dashboard or sales:event:{event_id}:orders.
```

---

## 12. Indexes and Queries

Required indexes:

```text
checkout_sessions(status, expires_at)
checkout_sessions(expires_at, id) where status in ('payment_link_sent', 'payment_started')
checkout_sessions(sales_order_id) unique or indexed according to VS-05
checkout_sessions(reservation_id) where reservation_id is not null
orders(status, inserted_at)
orders(event_id, status, inserted_at)
payment_attempts(sales_order_id, status)
state_transitions(entity_type, entity_id, inserted_at)
```

Query rules:

```text
Sweeper uses keyset pagination by expires_at/id.
Never query all expired sessions into memory.
Never scan all orders to find expired checkouts.
Dashboard expiry/manual-review views must use indexed status/reason fields.
```

---

## 13. RED/GREEN Test Plan

### RED tests first

```text
RED: sweeper enqueues bounded CheckoutExpiryWorker jobs for expired eligible sessions.
RED: non-expired checkout sessions are ignored.
RED: paid_verified orders are ignored by cleanup.
RED: already expired/released sessions are idempotent no-ops.
RED: worker releases Redis reservation once and marks checkout expired/released.
RED: duplicate workers do not double-release inventory.
RED: Redis release failure keeps checkout retryable and does not mark released.
RED: verified_success payment before cleanup routes to manual_review/late-payment policy and does not release inventory automatically.
RED: payment verified after cleanup cannot issue tickets automatically.
RED: no TicketIssue/Attendee/DeliveryAttempt records are created.
RED: no event_sync_version bump occurs.
RED: no scanner/mobile cache invalidation occurs.
RED: StateTransition rows are appended with non-PII metadata.
RED: logs do not include provider payloads, buyer phone/email, access_code, authorization_url, ticket_code, qr_token, or delivery_token.
```

### GREEN implementation targets

```text
GREEN: expiry worker is idempotent under repeat and concurrent execution.
GREEN: Redis ReservationLedger release/expire is the only inventory mutation path.
GREEN: DB state matches Redis release result.
GREEN: late payments are safe manual-review cases, not fulfillment cases.
GREEN: dashboard queues can read expired/manual-review outcomes efficiently.
GREEN: existing scanner, mobile sync, Tickera reconciliation, and issuance tests remain green.
```

---

## 14. Failure Modes

| Failure | Required behavior |
|---|---|
| Duplicate expiry worker | Idempotent no-op or reused released result; no double inventory increment. |
| Redis unavailable | Fail closed; retry through Oban; do not mark released. |
| DB commit fails after Redis release | Recovery/reconciliation must repair durable state from ledger/idempotency record. |
| Payment verifies before cleanup | Do not expire/release; classify through VS-07C. |
| Payment verifies after cleanup | No fulfillment; manual_review/refund_required. |
| Sweeper sees massive backlog | Bounded batches and recurring runs; no unbounded memory load. |
| Stale checkout link is opened | Link should show expired/unavailable; no new payment initialization from stale session. |
| Manual review closes checkout | Cleanup must not later rewrite terminal manual-review decisions. |

---

## 15. Performance and Scaling Review

```text
Hot data: Redis reservation ledger and idempotency keys.
Warm data: optional Redis counters for expiry metrics, TTL 7–30 days.
Cold data: CheckoutSession, Order, PaymentAttempt, StateTransition in Postgres.
Browser/cache: no customer-facing cache for expired checkout links.
CDN: no caching for checkout/payment pages.
```

Safety requirements:

```text
Safe under flash-sale spikes.
No direct DB polling from LiveView.
No long DB transactions.
No large table scans.
No inventory release without Redis idempotency.
No over-release.
No fulfillment after expiry.
```

Recommended telemetry:

```text
[:fastcheck, :sales, :checkout_expiry, :sweeper_started]
[:fastcheck, :sales, :checkout_expiry, :worker_started]
[:fastcheck, :sales, :checkout_expiry, :expired]
[:fastcheck, :sales, :checkout_expiry, :released]
[:fastcheck, :sales, :checkout_expiry, :skipped]
[:fastcheck, :sales, :checkout_expiry, :failed]
[:fastcheck, :sales, :checkout_expiry, :manual_review]
```

---

## 16. Security Rules

```text
Do not log buyer_phone, buyer_email, raw Paystack payloads, authorization_url, access_code, ticket_code, qr_token, delivery_token, or raw delivery token.
Only log correlation_id, checkout_session_id, sales_order_id, reservation_id hash/reference, and reason codes.
Expired checkout links must not expose payment URLs or access codes.
Expired checkout pages must use no-store/noindex headers.
Manual-review reasons must be non-PII stable reason codes.
```

---

## 17. TOON Coding-Agent Prompt

| Field | Content |
|---|---|
| Task | Implement VS-14 Checkout Expiry and Cleanup in `JCSchoeman96/FastCheckin`. |
| Objective | Safely expire stale unpaid checkout sessions, release Redis inventory holds exactly once, and prevent late/stale payment links from becoming fulfillment paths. |
| Output | `lib/fastcheck/sales/checkout_expiry.ex`, `lib/fastcheck/workers/checkout_expiry_worker.ex`, `lib/fastcheck/workers/checkout_expiry_sweeper_worker.ex`, Oban queue config update, minimal expiry indexes migration, and tests under `test/fastcheck/sales/` and `test/fastcheck/workers/`. |
| Note | FastCheckin repo truth: app root is `FastCheck`; Oban is configured in `config/config.exs`; Redis uses supervised `FastCheck.Redix`; scan hot-state already uses explicit keyspace/Lua/idempotency patterns. Use only `FastCheck.Sales.Inventory.ReservationLedger` for inventory release. Required indexes: `checkout_sessions(status, expires_at)`, partial `checkout_sessions(expires_at,id)` for open statuses, `checkout_sessions(reservation_id)`, `payment_attempts(sales_order_id,status)`, `orders(event_id,status,inserted_at)`, `state_transitions(entity_type,entity_id,inserted_at)`. TTL strategy: reservation/idempotency release keys must follow VS-04B/04C; optional expiry metrics Redis hash/list TTL 7–30d. Invalidation: Sales dashboard/order cache only; no attendee ETS invalidation, no event_sync_version bump, no scanner/mobile PubSub. Concurrency: Oban uniqueness plus DB locks/constraints plus Redis idempotency; no double release. Fail closed on Redis outage. No Paystack calls, no TicketIssue, no Attendee, no DeliveryAttempt, no WhatsApp/Meta, no refund execution. |
| Success | Expired unpaid sessions are closed and inventory is released once; duplicate/late workers are safe; late verified payments become manual-review/refund-required cases; stale links cannot issue tickets; all scanner/mobile/Tickera behavior remains unchanged. |

---

## 18. Copy-Paste Prompt for Coding Agent

```text
You are implementing FastCheck Sales VS-14 — Checkout Expiry and Cleanup in JCSchoeman96/FastCheckin.

Use FastCheckin as repo truth:
- app root: FastCheck
- Oban configured in config/config.exs
- Redis connection: FastCheck.Redix via FastCheck.Redis.Connection
- existing scanner/mobile state must not be changed

Implement:
1. FastCheck.Sales.CheckoutExpiry service.
2. FastCheck.Workers.CheckoutExpirySweeperWorker.
3. FastCheck.Workers.CheckoutExpiryWorker.
4. Oban queue config for sales_maintenance or repo-approved queue.
5. Minimal expiry indexes.
6. RED/GREEN tests.

Rules:
- Expire only CheckoutSession.status in payment_link_sent/payment_started and expires_at <= now.
- Do not expire paid_verified/fulfillment_queued/manual_review/terminal orders.
- Do not release inventory if a verified_success PaymentAttempt exists.
- Release inventory only through ReservationLedger.release/expire.
- Release must be idempotent and safe under duplicate workers.
- If Redis release fails, fail closed and retry; do not mark released.
- Append StateTransition rows with non-PII reason metadata.
- Do not create TicketIssue, Attendee, DeliveryAttempt, WhatsApp, Paystack, refund, scanner, or mobile sync behavior.
- Do not bump event_sync_version.
- Do not invalidate attendee ETS/mobile caches.

Tests must prove:
- bounded sweeper enqueue
- one-session worker expiry
- duplicate worker idempotency
- Redis failure retry behavior
- late payment safety
- no fulfillment after expiry
- no scanner/mobile/Tickera boundary creep
- log redaction
```

---

## 19. Human Review Checklist

```text
[ ] Oban queue configured without disrupting scan_persistence.
[ ] Sweeper queries are indexed and bounded.
[ ] Worker handles one checkout session only.
[ ] Expiry eligibility matches VS-05/VS-07C state machine.
[ ] ReservationLedger is the only inventory release path.
[ ] Redis failures do not mark checkouts released.
[ ] Duplicate workers cannot double-release inventory.
[ ] Late payment before cleanup is not expired incorrectly.
[ ] Late payment after cleanup cannot issue tickets automatically.
[ ] StateTransition audit rows are appended.
[ ] No TicketIssue/Attendee/DeliveryAttempt creation.
[ ] No Paystack/WhatsApp/refund execution.
[ ] No event_sync_version bump.
[ ] No attendee ETS/mobile cache invalidation.
[ ] Logs are PII/token safe.
[ ] Existing scanner, mobile sync, Tickera reconciliation, and issuance tests stay green.
```

---

## 20. Next Slice

```text
VS-15A — Core Revocation and Scanner Visibility
```
