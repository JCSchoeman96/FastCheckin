# FastCheck Sales Feature Planning Pack — VS-05 Order and Checkout Core

**Pack ID:** `0017_VS-05_order-and-checkout-core`  
**Repository path:** `docs/fastcheck_sales/feature_packs/0017_VS-05_order-and-checkout-core`  
**Slice:** `VS-05`  
**Slice name:** Order and Checkout Core  
**Version:** `v1.0`  
**Date:** 2026-06-12  
**Status:** Implementation planning pack — coding allowed only inside approved Sales checkout/order boundary  
**Primary area:** Ash / Sales / Checkout / Redis integration boundary / State transitions / Tests  
**Depends on:** VS-00A, VS-00B, VS-00C, VS-00D, VS-01B, VS-01C, VS-01F, VS-01G, VS-03, VS-04B  
**Blocks:** VS-04C, VS-05A, VS-06B, VS-07C late-payment behavior, VS-14  
**Source docs:**

```text
docs/fastcheck_sales/SOURCE_DOCS/FastCheck_Sales_Ash_Atlas_Planning_Pack_v0.2.3_HARDENED.md
docs/fastcheck_sales/SOURCE_DOCS/FastCheck_Sales_Vertical_Slice_Roadmap_v1.1.3_HARDENED.md
```

---

## 1. Purpose

This pack instructs a coding agent to implement the **core order and checkout workflow** for FastCheck Sales.

This is the first slice that connects durable Ash Sales state to the Redis inventory ledger. It must create safe order drafts, durable price snapshots, checkout sessions, and inventory holds without introducing Paystack HTTP, webhook verification, WhatsApp flows, ticket issuance, Attendee mutation, or scanner changes.

Strategic framing remains:

```text
FastCheck Sales is multi-channel, but WhatsApp is first.

Primary production customer channel:
  WhatsApp via Meta Cloud API

Secondary supported Sales paths:
  admin-assisted sales
  web checkout sales
  internal pilot sales

Every channel must use the same Sales core, Redis inventory ledger, Paystack verification path, idempotent ticket issuance path, DeliveryAttempt audit, and scanner-safe revocation path.
```

VS-05 must produce the checkout spine that all later entrypoints call. WhatsApp, admin-assisted sales, and web checkout must not each invent their own checkout logic.

---

## 2. Ultimate Outcome

After VS-05 is complete:

```text
Orders can be created as durable Sales orders through approved Ash/domain actions.
OrderLines preserve durable price snapshots.
CheckoutSessions can be created and linked to Orders.
Checkout creation reserves inventory through ReservationLedger only.
Checkout reservation is fail-closed if Redis/inventory is unavailable.
Checkout expiry hooks exist but expiry worker implementation remains in VS-14.
Payment-after-expiry policy hooks are represented in state/actions but Paystack verification remains later.
Every Order and CheckoutSession status change appends StateTransition.
All state transitions follow VS-00A legal matrices.
Actions are policy-protected according to VS-01F.
Tests prove success paths, failure paths, idempotency, policy denial, and Redis boundary safety.
No Paystack transaction initialization is implemented yet.
No ticket issuance or Attendee creation is implemented yet.
No WhatsApp or Meta API behavior is implemented yet.
```

The goal is not to sell a ticket end-to-end yet. The goal is to create a safe, reusable checkout core.

---

## 3. Scope

### In scope

```text
Implement approved Order Ash actions for draft/checkout lifecycle.
Implement approved OrderLine Ash actions for durable price snapshots.
Implement approved CheckoutSession Ash actions for checkout lifecycle.
Implement StateTransition recording for Order and CheckoutSession state changes.
Implement an approved checkout orchestration boundary that calls ReservationLedger.
Use TicketOffer reads to validate active offer, window, currency, max_per_order, and configured sales settings.
Use ReservationLedger.reserve/5 to create Redis inventory hold.
Persist redis_hold_key / hold_token / hold_quantity on CheckoutSession.
Make checkout creation idempotent by idempotency_key or public_reference where approved.
Add tests for order creation, order lines, checkout session creation, Redis hold attachment, and failure paths.
Add policy tests for system/admin/operator/customer_session access.
Add RED/GREEN tests before implementation.
Add telemetry/logging without PII/secrets.
```

### Out of scope

```text
No Paystack HTTP client.
No Paystack transaction initialization.
No webhook controller.
No payment verification.
No ticket issuing.
No Attendee creation.
No QR generation.
No delivery token generation beyond using existing skeleton fields if needed.
No WhatsApp/Meta API behavior.
No public web checkout UI.
No admin checkout UI.
No LiveView changes except compile-only fixes if unavoidable.
No scanner hot-path changes.
No Tickera reconciliation changes.
No Redis Lua changes unless a small bug fix is required by VS-04B tests and explicitly documented.
No Redis/Postgres reconciliation worker; that belongs to VS-04C/VS-14.
No generic update_status action.
```

---

## 4. Required Pre-Implementation Decisions

The coding agent must read and follow accepted outputs from:

```text
VS-00A State Machine and Failure Policy Finalization
VS-00B Security, PII, and Token Policy Finalization
VS-00C Inventory Recovery and Reconciliation Contract
VS-00D MVP Purchase Entry-Point and Launch Scope Decision
VS-01B Core Sales Resource Skeletons
VS-01C Checkout and Payment Resource Skeletons
VS-01F Ash Policy Foundation
VS-01G Index and Migration Verification
VS-03 Ticket Offer Management
VS-04B Atomic Inventory Ledger Implementation
```

### Required discovery step

Before changing code, the agent must locate and document actual repository paths for:

```text
FastCheck.Sales domain module
FastCheck.Sales.Order resource
FastCheck.Sales.OrderLine resource
FastCheck.Sales.CheckoutSession resource
FastCheck.Sales.TicketOffer resource
FastCheck.Sales.StateTransition resource
FastCheck.Sales.Inventory.ReservationLedger module
Ash policy actor helpers
existing Repo/transaction conventions
existing telemetry/logging conventions
existing PubSub module if checkout availability broadcasts are used
existing test data factories/support helpers
existing money/currency validation conventions
```

Do not create duplicate context, Repo, Redis, logging, or telemetry abstractions if the repository already has approved ones.

---

## 5. Domain and Boundary Details

### Ash domain to update

```text
FastCheck.Sales
```

### Ash resources to modify

```text
FastCheck.Sales.Order
FastCheck.Sales.OrderLine
FastCheck.Sales.CheckoutSession
FastCheck.Sales.StateTransition
```

### Ash resources to read/reference

```text
FastCheck.Sales.TicketOffer
```

### Plain Elixir modules to create or update

Preferred orchestration module:

```text
lib/fastcheck/sales/checkout.ex
```

Purpose:

```text
One approved checkout orchestration boundary that validates offer/order input, calls ReservationLedger, then invokes Ash actions to persist Order, OrderLine, CheckoutSession, and StateTransition records.
```

Alternative path is allowed only if the repository already has an equivalent Sales service/context naming convention. Do not put orchestration in controllers, LiveViews, Paystack modules, WhatsApp modules, or Ash resources directly if it requires Redis mutation.

### Preferred implementation files

```text
lib/fastcheck/sales/order.ex
lib/fastcheck/sales/order_line.ex
lib/fastcheck/sales/checkout_session.ex
lib/fastcheck/sales/state_transition.ex
lib/fastcheck/sales/checkout.ex
```

### Preferred test files

```text
test/fastcheck/sales/order_checkout_core_test.exs
test/fastcheck/sales/order_state_transition_test.exs
test/fastcheck/sales/order_line_snapshot_test.exs
test/fastcheck/sales/checkout_session_test.exs
test/fastcheck/sales/checkout_inventory_boundary_test.exs
test/fastcheck/sales/checkout_policy_test.exs
test/fastcheck/sales/checkout_idempotency_test.exs
```

### Forbidden paths for this slice

Do not modify these except for harmless compile fixes caused by approved changes:

```text
lib/fastcheck/payments/paystack/**
lib/fastcheck/messaging/whatsapp/**
lib/fastcheck/tickets/issuer.ex
lib/fastcheck/tickets/code_generator.ex
lib/fastcheck/tickets/qr_payload.ex
lib/fastcheck_web/**
lib/fastcheck/attendees/**
lib/fastcheck/events/**
lib/fastcheck/mobile/**
```

---

## 6. Required Ash Actions

Use Ash 3.x named actions. Do not add generic status updates.

### `FastCheck.Sales.Order`

Required actions:

```text
create_draft
confirm_checkout
mark_awaiting_payment
mark_payment_pending
expire_order
cancel_order
mark_manual_review
```

Allowed now only if the VS-00A matrix permits them and tests prove preconditions:

```text
mark_paid_unverified   # status hook only; no provider verification here
```

Forbidden in this slice:

```text
mark_paid_verified
queue_fulfillment
mark_ticket_issued
mark_partially_issued
mark_refunded
```

Those belong to Paystack verification, ticket issuance, and revocation slices.

### `FastCheck.Sales.OrderLine`

Required actions:

```text
create_for_order
list_for_order
```

Rules:

```text
OrderLine must snapshot ticket_type, offer_name_snapshot, event_name_snapshot, unit_amount_cents, total_amount_cents, and currency.
OrderLine must not recalculate historical price from TicketOffer after creation.
OrderLine.quantity must be positive.
OrderLine.total_amount_cents must equal quantity * unit_amount_cents.
```

### `FastCheck.Sales.CheckoutSession`

Required actions:

```text
create_session
attach_inventory_hold
mark_payment_link_sent      # status hook only; actual Paystack link creation is VS-06B
expire_session              # action exists; scheduled worker implementation belongs to VS-14
release_session             # action exists; release orchestration must use ReservationLedger
mark_manual_review
```

Forbidden in this slice:

```text
No payment provider call.
No ticket issuance.
No delivery behavior.
No direct Redis mutation inside the Ash resource.
```

### `FastCheck.Sales.StateTransition`

Required actions:

```text
record_transition
list_for_entity
```

Rules:

```text
Append-only.
No update.
No destroy.
Every Order and CheckoutSession state change must create a StateTransition.
Manual/admin transitions require non-empty reason.
System transitions should carry correlation_id or idempotency_key when available.
```

---

## 7. Checkout Orchestration Contract

All channel entrypoints must call one approved checkout API.

Recommended function shape:

```text
FastCheck.Sales.Checkout.start_checkout(input, actor, opts)
```

Recommended input fields:

```text
event_id
ticket_offer_id
quantity
buyer_name
buyer_phone
buyer_email
source_channel
idempotency_key
correlation_id
```

Allowed `source_channel` values:

```text
whatsapp
admin
web
system
test
internal_pilot
```

Required behavior:

```text
1. Validate actor and policy.
2. Load active TicketOffer through approved Sales reads.
3. Validate sales_enabled, sales window, currency, quantity, and max_per_order.
4. Calculate durable order total from TicketOffer snapshot.
5. Create or reuse idempotent Order draft.
6. Create OrderLine snapshot(s).
7. Call ReservationLedger.reserve/5.
8. If reservation fails, do not create a usable checkout session.
9. Create CheckoutSession with redis_hold_key, hold_token, hold_quantity, and expires_at.
10. Move Order to awaiting_payment only after hold is attached.
11. Append StateTransition rows for Order and CheckoutSession changes.
12. Return a safe result to caller without leaking raw internal state.
```

Preferred success return:

```text
{:ok, %{order: order, checkout_session: checkout_session}}
```

Preferred failure returns:

```text
{:error, :offer_not_found}
{:error, :sales_disabled}
{:error, :sales_window_closed}
{:error, :invalid_quantity}
{:error, :max_per_order_exceeded}
{:error, :insufficient_inventory}
{:error, :inventory_unavailable}
{:error, :duplicate_idempotency_conflict}
{:error, :forbidden}
```

Do not return raw provider payloads, Redis internals, tokens, or stack traces.

---

## 8. State Transition Requirements

### Order minimum transitions for this slice

```text
draft -> awaiting_payment
awaiting_payment -> payment_pending
awaiting_payment -> expired
awaiting_payment -> cancelled
draft -> cancelled
draft -> expired
any non-terminal allowed state -> manual_review when VS-00A permits it
```

Do not implement paid/ticket/refund transitions here except as explicitly allowed status hooks without external side effects.

### CheckoutSession minimum transitions for this slice

```text
created -> hold_attached
hold_attached -> payment_link_sent       # status hook only
hold_attached -> released
hold_attached -> expired
payment_link_sent -> payment_started     # status hook only if needed
payment_link_sent -> expired
payment_link_sent -> released
expired -> manual_review only if verified late payment exists later
released -> terminal unless explicit recovery exists
failed -> manual_review or terminal depending reason
```

### StateTransition rules

```text
from_state and to_state must be recorded for each state change.
entity_type must identify Order or CheckoutSession.
entity_id must identify the changed entity.
reason must be present for manual/admin transitions.
actor_type and actor_id must be captured when available.
metadata may include idempotency_key, redis_hold_key, source_channel, and correlation_id.
metadata must not include PII beyond allowed references and must not include tokens or provider payloads.
```

---

## 9. Inventory Integration Rules

VS-05 must use `FastCheck.Sales.Inventory.ReservationLedger` from VS-04B.

Required call pattern:

```text
ReservationLedger.reserve(offer_id, order_public_reference, quantity, ttl_seconds, idempotency_key)
```

Rules:

```text
No controller, LiveView, Ash resource, or checkout caller may write inventory Redis keys directly.
If Redis is unavailable, checkout must fail closed.
If reservation returns insufficient_inventory, no awaiting_payment order should be exposed as valid checkout.
If order/orderline persistence fails after reserve succeeds, orchestration must release the hold or mark the checkout/order for manual repair according to VS-00C policy.
If reservation succeeds and CheckoutSession persistence succeeds, the hold key must be stored durably.
Checkout expiry time must align with Redis hold TTL.
Availability display cache invalidation/broadcast may happen after reserve if already supported, but it must not block checkout correctness.
```

Compensation rule:

```text
If the code reserves inventory before durable checkout state is persisted and then durable persistence fails, call ReservationLedger.release/3 using the same order_public_reference/idempotency context before returning an error.
If release also fails, record an error/telemetry event and move any durable partial state to manual_review if it exists.
```

---

## 10. Payment-After-Expiry Hooks

This slice does not verify Paystack payments, but it must preserve enough state for later late-payment handling.

Required durable data:

```text
Order.expires_at
CheckoutSession.expires_at
CheckoutSession.redis_hold_key
CheckoutSession.hold_quantity
Order.status
CheckoutSession.status
StateTransition history
```

Rules:

```text
Expired checkout/order must not be treated as no-payment/no-ticket if later verified payment exists.
Late verified payment handling belongs to VS-07C and VS-14, but VS-05 must not make it impossible.
Do not delete expired orders or checkout sessions.
Do not hard-delete state needed for reconciliation or manual review.
```

---

## 11. Policy and Security Rules

### Actor expectations

```text
system can run checkout workflow and system transitions.
admin can create/admin-assist checkout if VS-00D allows admin-assisted path.
operator can only perform limited actions approved by VS-01F.
customer_session can use controlled checkout flow but cannot broadly read orders or checkout sessions.
```

### PII rules

```text
Do not log buyer_name, buyer_phone, buyer_email, phone_e164, recipient, raw_payloads, tokens, authorization URLs, access codes, or raw Redis values.
Use correlation_id, order public_reference, and non-sensitive ids in logs.
Admin/operator list views are out of scope, but tests must ensure checkout code does not expose raw sensitive fields in errors/logs.
```

### Token rules

```text
This slice must not create plaintext ticket delivery tokens.
This slice may store checkout hold identifiers only as required by VS-04A/VS-04B.
Do not expose hold_token to customers unless VS-00C explicitly allows it.
```

---

## 12. Performance and Scaling Review

### Data layering

```text
Hot inventory state: Redis via ReservationLedger.
Warm active offer display cache: Cachex/Redis from VS-03.
Cold durable truth: Postgres/Ash orders, order lines, checkout sessions, state transitions.
```

### Rules

```text
Checkout must not decrement Postgres TicketOffer counters as the live availability mechanism.
Checkout must not scan Order/OrderLine tables to decide live availability.
Checkout must use indexed offer/order/session lookup paths.
Checkout must be safe under duplicate requests with the same idempotency key.
Checkout should be safe under concurrent requests for the same offer.
StateTransition inserts must be append-only and indexed by entity_type/entity_id/inserted_at.
Do not load large collections into memory.
Do not add polling for availability.
Use PubSub broadcasts for availability changes only if already part of accepted cache strategy.
```

Target expectations:

```text
Sub-100ms local happy-path orchestration excluding network variance.
No excess DB reads on the hot reservation path.
No oversell under concurrent checkout attempts.
No duplicate durable orders for same idempotency key.
```

---

## 13. RED / GREEN Test Plan

The coding agent must write or update failing tests before implementation. Tests must become green after implementation.

### RED tests must fail when

```text
Order create_draft action is missing.
OrderLine create_for_order action is missing.
CheckoutSession create_session/attach_inventory_hold actions are missing.
Checkout orchestration module is missing.
Checkout can be created without ReservationLedger.reserve/5.
Checkout succeeds when Redis/inventory is unavailable.
Checkout succeeds when offer is disabled.
Checkout succeeds outside offer sales window.
Checkout succeeds with quantity <= 0.
Checkout succeeds over max_per_order.
Checkout creates OrderLine without price snapshot fields.
Order total does not equal sum of order lines.
Checkout does not store redis_hold_key/hold_quantity/expires_at.
Order moves to awaiting_payment before hold is attached.
StateTransition is not appended for Order state changes.
StateTransition is not appended for CheckoutSession state changes.
Manual/admin transition can occur without reason.
customer_session can broadly read all orders or checkout sessions.
operator can access raw payload or restricted checkout/payment internals.
Checkout errors/logs include PII, tokens, Redis internals, or raw payloads.
Checkout creates Paystack transaction or calls Paystack modules.
Checkout issues tickets or creates Attendee rows.
```

### GREEN tests require

```text
Valid checkout creates Order, OrderLine, CheckoutSession, and StateTransition rows.
Valid checkout reserves inventory through ReservationLedger.
OrderLine stores durable offer/price/currency snapshots.
Order total equals order line totals.
CheckoutSession stores hold details and expiry.
Order reaches awaiting_payment only after successful hold attachment.
Disabled/expired/not-yet-active offer is rejected safely.
Invalid quantity and max_per_order violations are rejected.
Insufficient inventory is rejected without valid checkout session.
Redis unavailable fails closed.
Duplicate request with same idempotency key is safe and does not double-reserve.
Persistence failure after reservation attempts compensation release or records manual repair according to policy.
StateTransition rows are append-only and complete.
Policies allow only approved actors/actions.
No forbidden modules/files are changed.
No PII/secrets/tokens/raw payloads appear in logs or error returns.
No Paystack, WhatsApp, TicketIssue, Attendee, or scanner behavior is added.
```

### Suggested test names

```text
test "valid checkout creates order, line, session, hold, and transitions"
test "checkout rejects disabled offer"
test "checkout rejects closed sales window"
test "checkout rejects quantity over max_per_order"
test "checkout fails closed when inventory ledger is unavailable"
test "checkout does not create valid awaiting_payment order when reserve fails"
test "checkout is idempotent by idempotency key"
test "order line snapshots price and offer name"
test "state transitions are appended for order and checkout session"
test "customer_session cannot broadly read orders"
test "checkout does not call Paystack or issue tickets"
test "checkout logs do not include PII or tokens"
```

---

## 14. Acceptance Criteria

This slice is Done only when:

```text
All required Order actions exist and follow approved state matrix.
All required OrderLine actions exist and snapshot price/offer data.
All required CheckoutSession actions exist and follow approved state matrix.
Checkout orchestration calls ReservationLedger and never mutates Redis directly elsewhere.
Checkout fails closed on inventory unavailability.
Checkout is idempotent for approved idempotency key behavior.
StateTransition is appended for every Order and CheckoutSession state change.
Policy tests prove actor restrictions.
Failure-path tests prove no unsafe checkout state on disabled offer, invalid quantity, insufficient inventory, or Redis outage.
Boundary tests prove no Paystack, WhatsApp, ticket issuance, Attendee, scanner, or UI behavior was added.
PII/log redaction checks pass.
Existing scanner tests still pass.
Markdown/docs are updated only where needed to describe implemented actions.
```

---

## 15. TOON Coding-Agent Prompt

| Field | Content |
|---|---|
| Task | Implement VS-05 Order and Checkout Core for FastCheck Sales. |
| Objective | Add safe order, order-line, checkout-session, and state-transition behavior that creates durable checkout intent only after Redis inventory is reserved through the approved ReservationLedger. This enables later Paystack initialization, WhatsApp checkout, web checkout, admin-assisted sales, expiry cleanup, and ticket issuance without allowing oversell or duplicate checkout state. |
| Output | Updated Ash resources and tests for `FastCheck.Sales.Order`, `FastCheck.Sales.OrderLine`, `FastCheck.Sales.CheckoutSession`, `FastCheck.Sales.StateTransition`, and an approved checkout orchestration module such as `lib/fastcheck/sales/checkout.ex`. Expected tests under `test/fastcheck/sales/*checkout*`, `*order*`, and `*policy*`. |
| Note | Use Ash 3.x named actions only. Do not add generic `update_status`. Do not call Paystack, Meta/WhatsApp, QR, ticket issuance, Attendees, scanner, or LiveView code. Checkout must call `FastCheck.Sales.Inventory.ReservationLedger.reserve/5`; no other module may mutate inventory Redis keys. Required indexes already come from VS-01G; do not remove them. Cache/TTL: checkout expiry must align with Redis hold TTL; active offer display cache invalidation may broadcast via PubSub if already available but must not block correctness. Hot data is Redis inventory hold state; cold durable truth is Postgres/Ash Order, OrderLine, CheckoutSession, StateTransition. Fail closed when Redis is unavailable. StateTransition rows are append-only. No PII/tokens/raw provider payloads in logs/errors. RED tests first, then GREEN implementation. |

---

## 16. Copy-Paste Agent Prompt

```text
You are implementing FastCheck Sales VS-05 — Order and Checkout Core.

Read these source docs first:
- docs/fastcheck_sales/SOURCE_DOCS/FastCheck_Sales_Ash_Atlas_Planning_Pack_v0.2.3_HARDENED.md
- docs/fastcheck_sales/SOURCE_DOCS/FastCheck_Sales_Vertical_Slice_Roadmap_v1.1.3_HARDENED.md
- Feature pack: 0017_VS-05_order-and-checkout-core/FEATURE_PACK.md

Goal:
Implement safe order and checkout core behavior using Ash 3.x and the existing Redis inventory ledger.

You must:
1. Update `FastCheck.Sales.Order`, `FastCheck.Sales.OrderLine`, `FastCheck.Sales.CheckoutSession`, and `FastCheck.Sales.StateTransition` with the approved named actions only.
2. Add or update one approved checkout orchestration boundary, preferably `lib/fastcheck/sales/checkout.ex`.
3. Validate active TicketOffer, sales window, currency, quantity, and max_per_order.
4. Create durable Order and OrderLine snapshots.
5. Reserve inventory only through `FastCheck.Sales.Inventory.ReservationLedger.reserve/5`.
6. Persist CheckoutSession hold details only after a successful hold.
7. Move Order to `awaiting_payment` only after hold attachment.
8. Append StateTransition for every Order and CheckoutSession status change.
9. Write RED tests first and make them GREEN.
10. Keep checkout idempotent by the approved idempotency key behavior.

Forbidden:
- Do not add Paystack transaction initialization.
- Do not call Paystack HTTP.
- Do not add webhook behavior.
- Do not add WhatsApp/Meta behavior.
- Do not issue tickets.
- Do not create Attendee rows.
- Do not touch scanner hot path.
- Do not add LiveView/admin/public UI.
- Do not mutate Redis inventory keys outside ReservationLedger.
- Do not add generic `update_status` actions.
- Do not log PII, tokens, authorization URLs, access codes, raw payloads, or Redis internals.

Required tests:
- valid checkout creates Order, OrderLine, CheckoutSession, Redis hold, and StateTransition records
- disabled/closed offer rejected
- invalid quantity and max_per_order rejected
- insufficient inventory rejected safely
- Redis unavailable fails closed
- idempotent duplicate checkout does not double-reserve
- OrderLine snapshots price and offer values
- Order cannot reach awaiting_payment before hold is attached
- StateTransition append-only behavior
- policy tests for system/admin/operator/customer_session
- boundary tests proving no Paystack, WhatsApp, ticket issuance, Attendee, scanner, or UI behavior

After implementation, report:
- files changed
- actions added
- tests added
- commands run
- RED/GREEN result summary
- any unresolved risks or deviations from this pack
```

---

## 17. Human Review Checklist

Before accepting this slice, verify:

```text
Checkout core is reusable by WhatsApp, admin-assisted, web checkout, and internal pilot paths.
ReservationLedger is the only inventory mutation boundary.
No Paystack or WhatsApp behavior slipped into checkout core.
OrderLine snapshots are durable and complete.
State transitions are explicit and audited.
Checkout fails closed under Redis outage.
Idempotency is tested.
Payment-after-expiry future behavior remains possible.
PII/log redaction rules are respected.
Scanner, Attendees, Events, and mobile API were not touched.
All tests listed in this pack either exist or are explicitly justified if not applicable.
```

---

## 18. Next Slice

```text
VS-05A — Secondary Sales Entry Points
```

VS-05A can only build entrypoint surfaces that call this checkout core. It must not duplicate order/checkout/reservation logic.
