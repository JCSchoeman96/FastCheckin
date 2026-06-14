# FastCheck Sales — Hardened Ash Atlas and Feature Planning Pack

**Project:** FastCheckin / FastCheck  
**Stack:** Elixir Phoenix, LiveView, PostgreSQL, Redis, Cachex, Oban, Req, Android scanner  
**Sales roadmap baseline:** FastCheck Sales Endgoal/Roadmap v1.0.1  
**Document type:** Hardened Ash architecture atlas and feature planning pack starting point  
**Version:** v0.2.3 hardened  
**Date:** 2026-06-12  
**Patch scope:** DOC 1 only. Clarifies multi-channel Sales strategy: WhatsApp-first as the primary production channel, with web/admin sales allowed as secondary paths.  

---

## 0. Purpose

This document defines the Ash planning layer for the FastCheck Sales platform.

It is intended to be used as the starting point for creating implementation-ready feature planning packs for coding agents.

The core architectural decision is:

```text
Use Ash 3.x for the new FastCheck Sales domain only.
Do not migrate the existing scanner, attendee, event, Tickera sync, or Android mobile API code into Ash as part of this roadmap.
```

Ash should model durable sales business state. It should not own Redis Lua scripts, Paystack HTTP calls, Meta Cloud API calls, QR rendering, or existing scanner runtime logic.

---


## 0.1 Implementation Readiness Status

This document is **architecture-ready but not implementation-ready** until the following hardening gates are complete:

1. All state machines have legal transition matrices.
2. Checkout/payment expiry edge cases are defined.
3. Redis inventory recovery and reconciliation rules are defined.
4. Ticket issuance idempotency and partial-failure behavior are defined.
5. Refund/revocation scanner visibility is defined.
6. Security, PII, token, and raw-provider-payload handling are defined.
7. Each vertical slice has acceptance criteria and failure-mode tests.

Until these are complete, coding agents may only work on planning, documentation, or isolated provider-boundary prototypes.

Blocking rule:

```text
Do not start Sales resource implementation until AFP-00A, AFP-00B, and AFP-00C are accepted.
```

---

## 1. Quick Recommendation

Use Ash 3.x for:

```text
FastCheck.Sales.TicketOffer
FastCheck.Sales.Order
FastCheck.Sales.OrderLine
FastCheck.Sales.CheckoutSession
FastCheck.Sales.PaymentAttempt
FastCheck.Sales.PaymentEvent
FastCheck.Sales.TicketIssue
FastCheck.Sales.DeliveryAttempt
FastCheck.Sales.Conversation
FastCheck.Sales.StateTransition
```

Do not use Ash for:

```text
FastCheck.Events
FastCheck.Attendees
FastCheck.Attendees.Scan
FastCheck.Attendees.Reconciliation
FastCheck.Events.Sync
FastCheck.Mobile
FastCheck.Redis.Connection
Existing Android mobile API endpoints
Existing scanner routes
Existing scanner hot path
```

Use plain Elixir modules for:

```text
FastCheck.Sales.Inventory.ReservationLedger
FastCheck.Sales.Inventory.RedisScripts
FastCheck.Payments.Paystack.Client
FastCheck.Payments.Paystack.WebhookVerifier
FastCheck.Payments.Paystack.TransactionVerifier
FastCheck.Messaging.WhatsApp.Client
FastCheck.Messaging.WhatsApp.WebhookVerifier
FastCheck.Tickets.CodeGenerator
FastCheck.Tickets.QrPayload
FastCheck.Tickets.DeliveryToken
FastCheck.Tickets.Issuer
```

---

## 2. Ultimate Goal

The long-term goal is a self-hosted event access and lightweight direct-sales platform where customers can buy tickets through WhatsApp, pay through Paystack, receive secure FastCheck ticket links or QR codes, and scan successfully through the existing FastCheck scanner path.

The finished flow should be:

```text
WhatsApp customer message
  -> Afrikaans-first number-only conversation flow
  -> FastCheck sales order
  -> Redis atomic inventory reservation
  -> Paystack backend transaction initialization
  -> Paystack webhook + transaction verification
  -> idempotent ticket issuance
  -> existing Attendee row creation
  -> cache invalidation + mobile sync version aggregation
  -> WhatsApp/email ticket delivery
  -> existing scanner accepts ticket
```

The Ash layer owns the durable Sales business state inside that flow.

---

## 2.1 Strategic Product Direction

FastCheck Sales is a **multi-channel Sales platform with WhatsApp first**.

The primary production sales channel is WhatsApp through the Meta Cloud API. Paystack is the payment provider. FastCheck Sales owns inventory reservation, payment verification state, ticket issuance, delivery audit, and scanner validity.

Web checkout and admin-assisted sales are allowed Sales paths, but they are secondary to the WhatsApp-first customer journey. They must use the same Sales core, inventory ledger, Paystack verification rules, ticket issuance rules, DeliveryAttempt audit model, and scanner-validity rules.

The Sales core must be built before any customer-facing channel so that every channel remains an interface layer only.

Non-negotiable rules:

```text
WhatsApp must not own inventory authority.
Web checkout must not own inventory authority.
Admin-assisted checkout must not bypass inventory authority.
No sales channel may own payment authority.
No sales channel may own ticket issuance authority.
No sales channel may mutate scanner-visible ticket validity directly.
All channels must call approved Sales, Checkout, Payment, Ticket, and Delivery services.
Paystack verification must happen server-side before ticket value is delivered.
```

Supported Sales channels:

```text
primary: whatsapp_first_paid_core
secondary: admin_assisted_sales
secondary: web_checkout_sales
internal: internal_pilot_sales
```

Channel priority:

```text
1. Build the Sales core safely.
2. Prove the Sales core through internal/admin-assisted testing if needed.
3. Launch WhatsApp-first customer sales through Meta Cloud API and Paystack.
4. Add or expand web checkout as a secondary sales path only after the shared Sales core and WhatsApp-first flow are stable.
```

A non-WhatsApp public paid launch must not become the default product direction. Web/admin paths are valid, but WhatsApp is the first and primary production customer channel.

---

## 2.2 Channel and Launch Entry-Point Decision

The roadmap must choose one primary launch channel and identify any secondary Sales paths before implementation starts.

Primary production launch channel:

```text
whatsapp_first_paid_core
```

Allowed secondary/build channels:

1. **Internal pilot sales**
   - Only test/admin-created orders are allowed.
   - Used to prove Sales, Paystack, issuance, scanner sync, and admin operations.
   - Not a public sales channel.

2. **Admin-assisted sales**
   - Operators manually create orders or checkout links for customers.
   - Useful for controlled pilots, support, and event-day operational sales.
   - Valid as a long-term secondary channel, but not the primary customer acquisition channel.

3. **Web checkout sales**
   - Public/customer-facing event checkout creates checkout sessions.
   - Valid as a secondary channel after the shared Sales core is stable.
   - Must not distract from the WhatsApp-first production launch.

4. **WhatsApp-first production sales**
   - WhatsApp inbound, number-only conversation flow, Paystack link, payment-pending handling, ticket resend, and delivery window behavior are part of the primary launch.
   - This is the first and primary production product direction.

Decisions required:

```text
Primary production channel: whatsapp_first_paid_core
Secondary channels for this release: TBD before VS-01A starts and before any checkout, payment, ticket-issuance, or customer-entrypoint implementation starts.

AFP-00 / VS-01A may install Ash and create the empty Sales domain shell only if it does not create business resources, checkout flows, payment behavior, or customer-facing behavior.
```

No payment integration should be considered launch-ready until the selected primary or secondary entrypoint is implemented and tested.

No primary production launch should be considered complete until the WhatsApp-first sales flow through Meta Cloud API is implemented, tested, and operationally supported.

Secondary web/admin channels may exist, but they must remain channel adapters over the same Sales core rather than separate business flows.

---

## 3. Architectural Boundary

### 3.1 Ash-owned boundary

Ash owns durable records and named business actions for direct sales:

```text
offers
orders
order lines
checkout sessions
payment attempts
payment events
ticket issue audit records
delivery attempts
conversation checkpoints
state transitions
```

### 3.2 Non-Ash boundary

The following must remain outside Ash:

```text
existing scanner/check-in logic
existing attendee Ecto schema/context
existing event Ecto schema/context
Tickera sync/reconciliation logic
Android mobile API
Redis Lua inventory logic
Paystack HTTP client/verifier
Meta Cloud API HTTP client/verifier
QR rendering/token encoding
Oban worker orchestration
```

### 3.3 Why this boundary matters

Bad architecture:

```text
Ash action directly calls Paystack
Ash action directly sends WhatsApp messages
Ash resource embeds Redis Lua inventory scripts
Ash resource creates Attendee rows as hidden side effects
LiveView directly updates Sales status columns
```

Good architecture:

```text
Ash stores durable Sales state
Plain modules handle Paystack and Meta HTTP calls
Plain Redis modules handle atomic inventory reservation
Oban workers orchestrate long-running work
Tickets.Issuer explicitly coordinates Ash Sales + existing Ecto Attendees
LiveView calls named Sales actions, not direct Repo updates
```

---


## 3.4 Global Domain Invariants

These invariants apply to every Sales resource and workflow.

1. All money amounts are stored as integer cents.
2. Currency must use ISO 4217 codes.
3. All status changes must go through named actions.
4. Generic `update_status` actions are forbidden.
5. Every status change must append a `StateTransition`.
6. External HTTP must not run inside Ash resource actions.
7. Redis Lua/scripts must not run inside Ash resources.
8. Ticket issuance must be idempotent.
9. Payment verification must check provider status, amount, currency, and reference.
10. A ticket must not be issued from webhook payload alone.
11. A cancelled/refunded/revoked ticket must become scanner-non-acceptable.
12. Customer-facing tokens must be hashed at rest.
13. Raw provider payloads must not be visible to operators by default.
14. Admin/manual overrides require an audit reason.
15. Redis is the hot operational ledger, but Postgres/Ash must be able to recover or reconcile durable business state.
16. No customer-facing response may contradict durable payment state.
17. No worker may rely on “runs once” behavior for correctness.
18. No public checkout may bypass the inventory reservation ledger.

## 3.5 Event and Tenant Isolation

The Sales domain must define its ownership boundary before implementation.

Decision required:

```text
Is FastCheck Sales single-tenant or multi-tenant?
```

If multi-tenant or future multi-tenant is expected, add:

```text
organization_id
```

or equivalent owner scope to all Sales-owned durable records:

```text
sales_ticket_offers
sales_orders
sales_order_lines
sales_checkout_sessions
sales_payment_attempts
sales_payment_events
sales_ticket_issues
sales_delivery_attempts
sales_conversations
sales_state_transitions
```

Policy rule:

```text
admin/operator access must be scoped by organization/event permissions, not only actor role.
```

No admin/operator list action may return records across unrelated events or organizations.

If the first release is intentionally single-tenant, state that explicitly in AFP-00B and still avoid coding broad assumptions that would block later tenant isolation.

---

## 4. Recommended Folder Layout

```text
lib/fastcheck/sales.ex

lib/fastcheck/sales/
  ticket_offer.ex
  order.ex
  order_line.ex
  checkout_session.ex
  payment_attempt.ex
  payment_event.ex
  ticket_issue.ex
  delivery_attempt.ex
  conversation.ex
  state_transition.ex

lib/fastcheck/sales/inventory/
  reservation_ledger.ex
  redis_scripts.ex

lib/fastcheck/payments/paystack/
  client.ex
  config.ex
  transaction_initializer.ex
  transaction_verifier.ex
  webhook_verifier.ex
  event_handler.ex

lib/fastcheck/messaging/whatsapp/
  client.ex
  webhook_verifier.ex
  conversation_state_machine.ex
  message_builder.ex
  template_catalog.ex

lib/fastcheck/tickets/
  issuer.ex
  code_generator.ex
  qr_payload.ex
  delivery_token.ex
  delivery_renderer.ex

lib/fastcheck/workers/
  expire_checkout_session_worker.ex
  paystack_webhook_worker.ex
  verify_payment_worker.ex
  issue_tickets_worker.ex
  send_whatsapp_ticket_worker.ex
  resend_ticket_worker.ex
  event_sync_version_aggregator_worker.ex

lib/fastcheck_web/controllers/webhooks/
  paystack_controller.ex
  whatsapp_controller.ex

lib/fastcheck_web/controllers/
  ticket_delivery_controller.ex

lib/fastcheck_web/live/sales/
  dashboard_live.ex
  order_show_live.ex
  manual_review_live.ex
```

### Naming recommendation

Use:

```text
FastCheck.Sales
```

as the Ash domain module.

Avoid:

```text
FastCheck.Sales.Domain
```

unless the existing project style strongly prefers explicit `Domain` suffixes.

Reason: `FastCheck.Sales` gives callers a clean domain boundary and matches Phoenix context naming conventions.

---

## 5. Ash Domain Atlas

## 5.1 `FastCheck.Sales`

Purpose:

```text
Own all durable direct-sales business state and actions:
offers, orders, checkout sessions, payment attempts, payment events,
ticket issue records, delivery attempts, conversations, and audit transitions.
```

Responsibilities:

```text
Expose named actions for Sales workflows.
Register Sales resources.
Keep resource actions intent-based.
Enforce policies and validations.
Avoid external HTTP and Redis side effects in resource actions.
```

Non-responsibilities:

```text
No Paystack HTTP calls.
No Meta Cloud API HTTP calls.
No Redis Lua scripts.
No existing Attendee scanner logic.
No direct Android API behavior.
```

---

# 6. Ash Resource Atlas

## 6.0 Field Type and Normalization Guidance

Implementation agents must follow these field conventions unless the existing codebase requires otherwise:

```text
*_cents fields: integer, non-negative
currency: ISO 4217 string, uppercase, usually 3 chars
buyer_phone / phone_e164 / recipient phone: normalized E.164 where possible
status/state fields: constrained enum/string values, never arbitrary text
state_data: map/jsonb
metadata: map/jsonb
raw_payload: restricted jsonb or encrypted jsonb if required
raw_initialize_response: restricted jsonb
raw_verify_response: restricted jsonb
provider_reference: string with unique provider scope
public_reference: opaque customer-safe reference, not sequential DB id
delivery_token_hash / qr_token_hash: hash only, never plaintext
lock_version: integer optimistic-lock field
inserted_at/updated_at: UTC timestamps
```

Rules:

```text
Do not store plaintext customer-facing tokens.
Do not use floats for money.
Do not use sequential DB IDs as customer-facing references.
Do not store provider payloads in plain logs.
```

## 6.1 `FastCheck.Sales.TicketOffer`

Represents a sellable ticket offer for an event.

```text
Table: sales_ticket_offers
```

### Fields

```text
id
organization_id       # required if tenant model is accepted
event_id
name
ticket_type
price_cents
currency
configured_quantity_available
initial_quantity
max_per_order
sales_enabled
sales_channel
starts_at
ends_at
lock_version
archived_at
inserted_at
updated_at
```

### Relationships

```text
has_many :order_lines
has_many :orders, through: order_lines
```

### Actions

```text
create_offer
update_offer
enable_sales
disable_sales
list_active_for_event
get_available_for_checkout
```

### Policies

```text
admin can create/update/disable
operator can read
system can read active offers
customer_session can only read active/sales_enabled offers through controlled service flow
```

### Notes

```text
Postgres owns durable offer configuration.
Redis owns hot availability during active sale windows.
Do not use this table as the flash-sale real-time counter.
configured_quantity_available is durable configured inventory, not the live flash-sale counter.
Live availability must be read from Redis during active checkout windows.
Use optimistic locking for admin edits to active offers.
Changing price, quantity, sales window, sales channel, or enabled status must invalidate Cachex, Redis warm caches, and LiveView/PubSub display state.
Cache active offers in Cachex for 1–5 minutes.
Redis warm cache key: sales:event:{event_id}:offers, TTL 30m.
Invalidate on create/update/disable/archive.
```

---

## 6.2 `FastCheck.Sales.Order`

Represents a buyer order.

```text
Table: sales_orders
```

### Fields

```text
id
organization_id       # required if tenant model is accepted
public_reference
event_id
buyer_name
buyer_phone
buyer_email
source_channel        # web, whatsapp, admin, system, test
status
total_amount_cents
currency
whatsapp_conversation_id
idempotency_key
expires_at
paid_at
fulfillment_queued_at
ticket_issued_at
cancelled_at
expired_at
refunded_at
manual_review_reason
last_error_code
last_error_message
lock_version
inserted_at
updated_at
```

### Relationships

```text
has_many :order_lines
has_many :payment_attempts
has_many :ticket_issues
has_many :delivery_attempts
belongs_to :conversation
```

### Actions

```text
create_draft
confirm_checkout
mark_awaiting_payment
mark_payment_pending
mark_paid_unverified
mark_paid_verified
queue_fulfillment
mark_ticket_issued
mark_partially_issued
mark_manual_review
expire_order
cancel_order
mark_refunded
```

### Policies

```text
system can run payment and fulfillment transitions
admin can read/manage
operator can read and perform allowed manual-review actions
customer_session cannot broadly read orders
customer can only access ticket/order through secure delivery token flow
```

### Notes

```text
Order status must be treated as a state machine, not a free-form field.
Every status change must append a StateTransition.
Do not transition to ticket_issued unless ticket issue rows exist.
Do not transition to paid_verified unless Paystack verification passed status, amount, currency, and reference checks.
Do not perform external HTTP inside order actions.
Terminal states are ticket_issued, cancelled, expired, and refunded.
Terminal states may only be exited through explicitly documented manual recovery actions.
mark_paid_verified requires payment attempt ownership, verified provider status, amount match, currency match, and provider reference match.
mark_ticket_issued requires paid_verified or fulfillment_queued order state, attendee rows, ticket_issue rows, and event sync aggregation enqueue.
```

---

## 6.3 `FastCheck.Sales.OrderLine`

Represents a durable price snapshot of a purchased offer.

```text
Table: sales_order_lines
```

### Fields

```text
id
sales_order_id
ticket_offer_id
line_number
ticket_type
offer_name_snapshot
event_name_snapshot
quantity
unit_amount_cents
total_amount_cents
currency
metadata
inserted_at
updated_at
```

### Relationships

```text
belongs_to :order
belongs_to :ticket_offer
has_many :ticket_issues
```

### Actions

```text
create_for_order
list_for_order
```

### Policies

```text
system creates
admin/operator reads
no public direct mutation
```

### Notes

```text
Never recalculate historical price from TicketOffer after order creation.
OrderLine is the durable price snapshot.
OrderLine must preserve the customer-facing offer name and pricing visible at checkout time.
Never rely on current TicketOffer values when rendering historical orders, receipts, tickets, or support views.
```

---

## 6.4 `FastCheck.Sales.CheckoutSession`

Represents durable checkout lifecycle state.

```text
Table: sales_checkout_sessions
```

### Fields

```text
id
sales_order_id
status
redis_hold_key
hold_token
hold_quantity
payment_link_sent_at
released_at
expired_at
last_seen_at
expires_at
state_data
lock_version
inserted_at
updated_at
```

### Relationships

```text
belongs_to :order
```

### Actions

```text
create_session
attach_inventory_hold
mark_payment_link_sent
expire_session
release_session
```

### Policies

```text
system can create/update
admin/operator can read
customer cannot directly read this resource
```

### Notes

```text
Redis owns the hot inventory hold.
This table records durable checkout intent.
Do not rely on this table for atomic inventory availability.
A checkout session may expire before payment is received.
A verified payment after checkout expiry must not blindly issue tickets.
The payment-after-expiry policy must be applied before fulfillment.
```

---

## 6.5 `FastCheck.Sales.PaymentAttempt`

Represents one Paystack transaction attempt.

```text
Table: sales_payment_attempts
```

### Fields

```text
id
sales_order_id
provider
provider_reference
idempotency_key
authorization_url
access_code
status
provider_status
amount_cents
currency
initialized_at
provider_paid_at
verified_at
last_verified_at
verification_attempt_count
failure_code
failure_message
manual_review_reason
raw_initialize_response
raw_verify_response
inserted_at
updated_at
```

### Relationships

```text
belongs_to :order
has_many :payment_events
```

### Actions

```text
create_initialized
mark_authorization_url_sent
mark_webhook_received
mark_verification_started
mark_verified_success
mark_amount_mismatch
mark_currency_mismatch
mark_failed
mark_duplicate
mark_manual_review
```

### Policies

```text
system can create/update
admin/operator can read
customer never reads raw provider responses
```

### Notes

```text
Unique provider + provider_reference is mandatory.
Never expose authorization internals beyond the customer payment URL.
Paystack client/verifier must remain plain modules outside Ash.
A Paystack webhook is not proof of payment.
Only server-side transaction verification can move an attempt to verified_success.
```

---

## 6.6 `FastCheck.Sales.PaymentEvent`

Represents a raw Paystack webhook event.

```text
Table: sales_payment_events
```

### Fields

```text
id
provider
provider_event_id
provider_reference
event_type
signature_valid
payload_hash
raw_payload
received_at
processed_at
processing_status
processing_attempt_count
last_processing_error
last_processing_error_at
inserted_at
updated_at
```

### Relationships

```text
optionally relates to PaymentAttempt by provider_reference
```

### Actions

```text
store_webhook_event
mark_processing_started
mark_processed
mark_duplicate
mark_unmatched
mark_failed
mark_manual_review
```

### Policies

```text
system creates
admin/operator reads summarized view
raw payload access restricted to admin/system
```

### Notes

```text
Webhook controller verifies, stores, enqueues, and returns quickly.
Heavy processing happens in Oban.
Use unique DB index plus Redis SETNX dedupe key.
Deduplicate by provider/provider_event_id and payload_hash.
Unmatched payment events must not be deleted immediately.
They should remain queryable for retry/manual review.
```

---

## 6.7 `FastCheck.Sales.TicketIssue`

Represents a ticket issued from a verified order.

```text
Table: sales_ticket_issues
```

### Fields

```text
id
sales_order_id
sales_order_line_id
line_item_sequence
attendee_id
ticket_code
qr_token_hash
delivery_token_hash
delivery_token_expires_at
status
scanner_status
last_scanner_sync_version
issued_at
revoked_at
revocation_reason
inserted_at
updated_at
```

### Relationships

```text
belongs_to :order
belongs_to :order_line
has_many :delivery_attempts
```

### Actions

```text
create_pending
mark_issued
mark_revoked
mark_manual_review
```

### Policies

```text
system creates/updates
admin/operator reads and can trigger resend/revoke workflows
customer access only through secure token
```

### Notes

```text
Attendee creation remains in existing Ecto context.
TicketIssue records the Sales-side audit link to the attendee row.
Ticket issuing must be idempotent.
line_item_sequence starts at 1 for each order line and is used to issue exactly one ticket per purchased quantity unit.
Customer-facing delivery tokens must never be stored in plaintext.
Only token hashes may be stored.
Revoked/refunded/cancelled ticket issues must become scanner-non-acceptable through the existing scanner-visible attendee/sync path.
TicketIssue.status represents ticket issuance and validity, not delivery-attempt history.
DeliveryAttempt is the source of truth for delivery attempts, provider responses, fallback, and resend history.
TicketIssue may expose a derived delivery summary in admin views, but that summary must not replace DeliveryAttempt audit records.
```

---

## 6.8 `FastCheck.Sales.DeliveryAttempt`

Represents every attempt to deliver a ticket through WhatsApp or email.

```text
Table: sales_delivery_attempts
```

### Fields

```text
id
sales_order_id
ticket_issue_id
channel
provider
recipient
status
template_name
within_whatsapp_window
provider_message_id
attempt_number
provider_error_code
provider_error_message
failure_reason
fallback_channel
correlation_id
sent_at
delivered_at
inserted_at
updated_at
```

### Relationships

```text
belongs_to :order
belongs_to :ticket_issue
```

### Actions

```text
create_queued
mark_sent
mark_delivered
mark_failed
mark_fallback_required
```

### Policies

```text
system creates/updates
admin/operator reads
recipient field should be protected from casual display where possible
```

### Why this resource is required

A single ticket can have multiple delivery attempts:

```text
WhatsApp session message
WhatsApp approved utility template
email fallback
admin resend
```

Storing only `ticket_issues.delivered_at` is too thin for support, audit, and Meta 24-hour window handling.

A failed WhatsApp session message must not be silently dropped.
If the 24-hour window is closed, delivery must attempt an approved utility template or move to fallback/manual_review according to the delivery policy.

---

## 6.9 `FastCheck.Sales.Conversation`

Represents persisted WhatsApp conversation checkpoints.

```text
Table: sales_conversations
```

### Fields

```text
id
phone_e164
wa_id
session_key
rate_limit_key
preferred_language
locale
state
state_data
last_inbound_message_id
last_outbound_message_id
last_message_at
expires_at
needs_human
handoff_reason
inserted_at
updated_at
```

### Relationships

```text
has_many :orders
```

### Actions

```text
start_or_resume
select_language
move_to_main_menu
select_event
select_offer
select_quantity
collect_buyer_name
collect_email
confirm_order
mark_awaiting_payment
mark_payment_pending
mark_ticket_issued
mark_needs_human
expire_conversation
```

### Policies

```text
system can create/update
admin/operator can read support view
customer does not query resource directly
```

### Notes

```text
Redis owns active WhatsApp session state.
Ash/Postgres stores durable checkpoints and audit state.
Conversation state must be recoverable enough to avoid customer confusion after Redis loss.
Afrikaans first, English second.
Number-only navigation.
If payment is pending, do not tell customer no ticket exists.
```

---

## 6.10 `FastCheck.Sales.StateTransition`

Represents immutable audit history.

```text
Table: sales_state_transitions
```

### Fields

```text
id
entity_type
entity_id
from_state
to_state
reason
actor_type
actor_id
metadata
correlation_id
request_id
idempotency_key
source
inserted_at
```

### Relationships

```text
none required initially
```

### Actions

```text
record_transition
list_for_entity
list_recent_for_dashboard
```

### Policies

```text
system creates
admin/operator reads
no update
no destroy
```

### Notes

```text
Append-only.
No destructive deletes.
Required for disputes, audit, and manual review.
Manual admin/operator transitions must include a non-empty reason.
System transitions should include correlation_id or idempotency_key when available.
```

---

# 7. Optional Later Ash Resources

Do not include these in MVP unless the need becomes concrete.

## 7.1 `FastCheck.Sales.InventorySnapshot`

Purpose:

```text
Durable record of Redis/Postgres inventory reconciliation snapshots.
```

Use when flash-sale reconciliation reporting becomes important.

## 7.2 `FastCheck.Sales.RefundRecord`

Purpose:

```text
Track refund request, manual refund, and provider refund state.
```

MVP can use order/ticket status plus StateTransition.

## 7.3 `FastCheck.Sales.AdminNote`

Purpose:

```text
Support/admin notes on orders or tickets.
```

Useful later, but not core to safe checkout.

---


## 7.4 `FastCheck.Sales.TicketDeliveryToken`

Purpose:

```text
Track hashed customer-facing ticket access tokens, expiry, revocation, resend rotation, and audit.
```

Use when:

```text
multiple resend links are allowed
admin can revoke/reissue ticket links
delivery links need expiry history
support needs to know which link was sent when
```

MVP option:

```text
store one active token hash directly on TicketIssue
```

Hardened option:

```text
use a first-class TicketDeliveryToken resource
```

Do not store plaintext delivery tokens in any table.

---

# 8. Relationship Atlas

```text
TicketOffer
  has_many OrderLine

Order
  has_many OrderLine
  has_many PaymentAttempt
  has_many TicketIssue
  has_many DeliveryAttempt
  belongs_to Conversation

OrderLine
  belongs_to Order
  belongs_to TicketOffer
  has_many TicketIssue

CheckoutSession
  belongs_to Order

PaymentAttempt
  belongs_to Order
  has_many PaymentEvent by provider_reference/provider_reference

PaymentEvent
  optionally relates to PaymentAttempt by provider_reference

TicketIssue
  belongs_to Order
  belongs_to OrderLine
  has_many DeliveryAttempt
  optionally has_many TicketDeliveryToken if token history becomes first-class
  references existing Attendee by attendee_id, but Attendee is not Ash

DeliveryAttempt
  belongs_to Order
  belongs_to TicketIssue

Conversation
  has_many Order

StateTransition
  polymorphic audit reference by entity_type/entity_id
```

---

# 9. State Atlas

## 9.1 Order states

```text
draft
awaiting_payment
payment_pending
paid_unverified
paid_verified
fulfillment_queued
ticket_issued
partially_issued
manual_review
cancelled
expired
refunded
```

## 9.2 Payment states

```text
initialized
authorization_url_sent
webhook_received
verification_started
verified_success
verified_amount_mismatch
verified_currency_mismatch
failed
duplicate
manual_review
refunded
```

## 9.3 Ticket issue states

```text
pending
issued
revoked
manual_review
```

## 9.4 Delivery attempt states

```text
queued
sent
delivered
failed
fallback_required
cancelled
manual_review
```

## 9.5 Conversation states

```text
new
selecting_language
main_menu
selecting_event
selecting_ticket_type
collecting_quantity
collecting_buyer_name
collecting_email
confirming_order
awaiting_payment
payment_pending
payment_received
ticket_issued
completed
manual_review
cancelled
expired
```

---


## 9.6 Checkout session states

```text
created
hold_attached
payment_link_sent
payment_started
paid
expired
released
failed
manual_review
```

## 9.7 Payment After Expiry Policy

Payments can arrive after checkout or inventory holds expire.

Required outcomes:

| Case | Outcome |
|---|---|
| Payment verified before hold expiry | Consume Redis hold and issue ticket. |
| Payment verified after hold expiry and inventory is still available | Re-reserve/consume inventory, then issue ticket. |
| Payment verified after hold expiry and inventory is unavailable | Move order and payment attempt to manual_review. Do not issue ticket automatically. |
| Webhook arrives after order expired | Verify payment, record event, then apply expiry policy. |
| Duplicate payment/webhook for already-issued order | Mark duplicate/idempotent success. Do not issue again. |
| Amount/currency/reference mismatch | Mark manual_review. Do not issue ticket. |

No customer-facing message may say “no payment received” after a verified payment exists.

## 9.8 Legal State Transition Matrices

Every state machine must define this table before implementation:

```text
from_state
allowed_to_state
actor_type
required_preconditions
side_effects
audit_required?
terminal?
```

Required matrices:

1. Order transition matrix
2. CheckoutSession transition matrix
3. PaymentAttempt transition matrix
4. PaymentEvent processing matrix
5. TicketIssue transition matrix
6. DeliveryAttempt transition matrix
7. Conversation transition matrix

No coding-agent implementation may create or modify statuses until these matrices exist.

### 9.8.1 Minimum Order transition constraints

```text
draft -> awaiting_payment | cancelled | expired
awaiting_payment -> payment_pending | paid_unverified | paid_verified | expired | cancelled
payment_pending -> paid_unverified | paid_verified | manual_review | expired | cancelled
paid_unverified -> paid_verified | manual_review
paid_verified -> fulfillment_queued | manual_review | refunded
fulfillment_queued -> ticket_issued | partially_issued | manual_review
partially_issued -> ticket_issued | manual_review | refunded
manual_review -> allowed recovery target only with admin/system reason
cancelled -> terminal unless explicit admin recovery action exists
expired -> terminal unless verified late payment recovery action exists
refunded -> terminal unless explicit admin recovery action exists
ticket_issued -> refunded | manual_review
```

Rules:

```text
ticket_issued -> refunded requires:
- refund/revocation path exists
- TicketIssue revocation is recorded
- existing Attendee/scanner visibility is updated
- event sync aggregation is enqueued
- StateTransition reason is required
- customer delivery/token access is revoked or marked invalid
```

### 9.8.2 Minimum CheckoutSession transition constraints

```text
created -> hold_attached | failed | expired
hold_attached -> payment_link_sent | released | expired | failed
payment_link_sent -> payment_started | released | expired | failed
payment_started -> paid | expired | manual_review
paid -> terminal idempotent success
released -> terminal unless explicit recovery action exists
expired -> manual_review only if verified late payment exists
failed -> manual_review or terminal depending reason
manual_review -> explicit admin/system recovery only
```

Rules:

```text
released and expired sessions must not release already-consumed holds.
paid requires verified payment handling and inventory consume/re-reserve policy.
expired with verified late payment must follow payment-after-expiry policy.
```

### 9.8.3 Minimum PaymentAttempt transition constraints

```text
initialized -> authorization_url_sent | failed | manual_review
authorization_url_sent -> webhook_received | verification_started | failed | manual_review
webhook_received -> verification_started | duplicate | manual_review
verification_started -> verified_success | verified_amount_mismatch | verified_currency_mismatch | failed | manual_review
verified_success -> refunded
verified_amount_mismatch -> manual_review
verified_currency_mismatch -> manual_review
failed -> manual_review or terminal depending reason
duplicate -> terminal idempotent outcome
manual_review -> explicit admin/system recovery only
```

Rules:

```text
Duplicate webhook/verification after verified_success returns idempotent success and records duplicate handling on PaymentEvent, StateTransition metadata, or worker logs.
It must not downgrade, overwrite, or replace the PaymentAttempt verified_success state.
```

### 9.8.4 Minimum PaymentEvent processing constraints

```text
stored -> processing_started | duplicate | unmatched | failed
processing_started -> processed | unmatched | failed | duplicate
unmatched -> processing_started | manual_review
failed -> processing_started | manual_review
duplicate -> terminal idempotent outcome
processed -> terminal idempotent outcome
manual_review -> explicit admin/system recovery only
```

Rules:

```text
Invalid signatures may be stored for audit but must not trigger payment verification.
Unmatched events must remain queryable and retryable.
Duplicate events must not mutate verified payment/order state.
```

### 9.8.5 Minimum TicketIssue transition constraints

```text
pending -> issued | manual_review
issued -> revoked | manual_review
revoked -> terminal unless explicit admin recovery action exists
manual_review -> explicit admin/system recovery only
```

Rules:

```text
TicketIssue.status owns ticket issuance and validity only.
DeliveryAttempt owns delivery provider history, fallback, resend attempts, and delivery audit.
Revocation must update the existing scanner-visible attendee path and enqueue event sync aggregation.
```

### 9.8.6 Minimum DeliveryAttempt transition constraints

```text
queued -> sent | failed | fallback_required | cancelled
sent -> delivered | failed | fallback_required
delivered -> terminal success
failed -> fallback_required | manual_review | cancelled
fallback_required -> queued | failed | manual_review
cancelled -> terminal unless explicit resend/retry action exists
manual_review -> explicit admin/system recovery only
```

Rules:

```text
A failed session message must not silently disappear.
If the WhatsApp 24-hour window is closed, use the approved utility template or fallback policy.
DeliveryAttempt is the source of truth for delivery audit.
```

### 9.8.7 Minimum Conversation transition constraints

```text
new -> selecting_language | main_menu | expired
selecting_language -> main_menu | expired | manual_review
main_menu -> selecting_event | completed | manual_review | expired
selecting_event -> selecting_ticket_type | main_menu | expired
selecting_ticket_type -> collecting_quantity | main_menu | expired
collecting_quantity -> collecting_buyer_name | main_menu | expired
collecting_buyer_name -> collecting_email | confirming_order | expired
collecting_email -> confirming_order | expired
confirming_order -> awaiting_payment | main_menu | cancelled | expired
awaiting_payment -> payment_pending | payment_received | manual_review | expired
payment_pending -> payment_received | ticket_issued | manual_review
payment_received -> ticket_issued | manual_review
ticket_issued -> completed | manual_review
manual_review -> completed | expired | cancelled with reason
cancelled -> terminal unless explicit restart
expired -> terminal unless start_or_resume creates a new session
completed -> terminal unless explicit resend/support flow
```

Rules:

```text
Payment-pending conversation messages must not tell the customer that payment/ticket does not exist when durable payment state exists.
Redis hot state may expire, but Postgres checkpoints must preserve enough state to avoid customer confusion.
```
---

# 10. Policy Model

## 10.1 Actor types

Use this simple actor shape for Ash policies:

```text
system
admin
operator
customer_session
```

## 10.2 Permissions

### `system`

Can:

```text
run webhook actions
run payment verification transitions
run ticket fulfillment transitions
run delivery transitions
run conversation transitions
record state transitions
```

### `admin`

Can:

```text
read/manage sales resources
create/update/disable ticket offers
perform manual review
cancel orders
mark refunded
resend tickets
view audit timelines
```

### `operator`

Can:

```text
read sales dashboard
view order/ticket support state
resend tickets
mark conversation needs_human
perform limited manual-review actions
```

### `customer_session`

Can:

```text
use controlled checkout/conversation service flow only
not perform broad Ash reads
not mutate orders directly
not access raw payment or delivery internals
```

---


## 10.3 Security, PII, and Token Policy

PII fields:

```text
buyer_name
buyer_phone
buyer_email
phone_e164
recipient
raw provider payloads that contain customer data
WhatsApp state_data that may contain customer data
```

Rules:

1. Admin list views should mask phone/email by default.
2. Operator views should not expose raw provider payloads.
3. Raw Paystack/Meta payload access is restricted to admin/system.
4. Customer-facing delivery tokens must be stored hashed, never plaintext.
5. Logs must redact phone, email, access_code, authorization_url, raw payloads, and tokens.
6. Delivery tokens must support expiry and revocation.
7. Manual review screens must show enough detail for support without dumping raw payloads by default.
8. Retention policy for raw provider payloads must be defined before production launch.
9. AFP-00B must produce the raw provider payload retention policy before VS-07A webhook ingestion is implemented.
10. `customer_session` must never perform broad Ash reads.
11. `operator` must not be treated as equivalent to `admin`.

## 10.4 Policy Test Requirements

Each resource must include policy tests for:

```text
system allowed actions
admin allowed actions
operator allowed actions
customer_session allowed controlled reads/actions
customer_session forbidden broad reads
operator forbidden raw provider payload access
tenant/event isolation if organization_id is accepted
field-level restrictions for PII and raw payloads
```

---

# 11. Action Design Rules

## Rule 1 — No external HTTP inside Ash actions

Do not call Paystack or Meta inside resource actions.

Reason:

```text
External HTTP inside DB transactions risks long locks, timeouts, and unsafe retries.
```

## Rule 2 — No Redis Lua inside Ash resources

Redis inventory is a hot operational ledger, not durable Ash state.

Correct split:

```text
Sales.Inventory.ReservationLedger.reserve(...)
Sales.Order.confirm_checkout(...)
```

## Rule 3 — State transitions must be explicit

Do not use generic `update_status` actions.

Use named transitions:

```text
mark_awaiting_payment
mark_paid_verified
mark_manual_review
expire_order
mark_refunded
```

## Rule 4 — Every state change must append a StateTransition

This should be implemented through a reusable change/action helper where possible.

## Rule 5 — Ash actions must not hide Attendee mutation

Ticket issuance crosses into the existing Ecto Attendees domain.

That belongs in:

```text
FastCheck.Tickets.Issuer
```

not hidden inside `Sales.Order`.

---

# 12. Cross-Boundary Issuance Pattern

This is the most important technical boundary.

```text
IssueTicketsWorker
  -> Tickets.Issuer.issue_order(order_id)
      -> lock/load Sales.Order
      -> validate paid_verified
      -> create Attendee rows through existing Ecto schema/context
      -> create Sales.TicketIssue records
      -> mark Order fulfillment/ticket state
      -> enqueue sync version aggregation
      -> commit or compensate
```

## Recommendation

Use one deliberate orchestration service:

```text
lib/fastcheck/tickets/issuer.ex
```

This service coordinates Ash Sales records and existing Ecto Attendee records.

Do not let controllers, workers, or LiveViews each implement their own version of ticket issuing.

## Risks this prevents

```text
order marked ticket_issued but attendee not created
attendee created but ticket_issue missing
ticket issued twice after retry
order paid but never fulfilled
manual review cannot explain state
```

---


## 12.1 Ticket Issuance Transaction/Saga Contract

Ticket issuance must choose one implementation model before AFP-10 / VS-09 starts.

Preferred model if Ash Sales and existing Attendees use the same Repo:

```text
one database transaction
  lock order
  verify paid_verified
  load order lines
  create attendee rows idempotently
  create ticket_issue rows idempotently
  mark order ticket_issued or partially_issued
  enqueue event sync aggregation
commit
```

Required idempotency keys:

```text
sales_order_id
sales_order_line_id
line_item_sequence
ticket_code
attendee_sales_origin_reference
```

Partial failure behavior:

| Failure | Required behavior |
|---|---|
| Some attendee rows created, TicketIssue insert fails | Retry must link existing attendee rows and complete TicketIssue records. |
| TicketIssue rows created, order transition fails | Retry must detect existing issues and complete order transition. |
| Order already ticket_issued | Retry returns idempotent success. |
| Duplicate worker execution | Must not create duplicate attendees or tickets. |
| One ticket in multi-ticket order fails | Move order to partially_issued or manual_review according to matrix. |

Controllers, webhooks, and LiveViews must never issue tickets directly.
Only `FastCheck.Tickets.Issuer.issue_order/1` may coordinate issuing.

## 12.2 Attendee Origin Protection Contract

FastCheck-sales-created attendees must be protected from Tickera reconciliation.

Required existing Attendee-side behavior:

1. Sales-created attendees must have a clear origin marker.
2. Tickera sync/reconciliation must not delete or overwrite Sales-created attendees.
3. Refunded/revoked Sales tickets must become scanner-non-acceptable.
4. Event mobile sync version must be bumped/debounced after Sales attendee changes.
5. Existing scanner hot path must remain isolated and carefully reviewed.

Recommended attendee fields or equivalent:

```text
source
source_reference
sales_order_id
sales_ticket_issue_id
revoked_at
revocation_reason
scanner_status
```

Exact field names should match existing Attendees schema conventions.

---

# 13. Redis / Ash Boundary

## Redis owns hot reservation state

```text
sales:offer:{offer_id}
sales:offer:{offer_id}:holds
sales:hold:{public_reference}
sales:order:{public_reference}:lock
```

## Ash/Postgres owns durable state

```text
sales_ticket_offers
sales_orders
sales_order_lines
sales_checkout_sessions
sales_payment_attempts
sales_payment_events
sales_ticket_issues
sales_delivery_attempts
sales_conversations
sales_state_transitions
```

## Important rule

Ash resources may store Redis keys and status snapshots, but Redis operations must be done by plain modules.

Correct:

```text
ReservationLedger.reserve(...)
then Ash action updates CheckoutSession/Order state
```

Avoid:

```text
TicketOffer action runs Lua directly
Order action mutates Redis availability directly
```

---


## 13.1 Redis Inventory Ledger Contract

The Redis inventory module must expose these operations:

```text
reserve(offer_id, order_public_reference, quantity, ttl_seconds, idempotency_key)
consume(offer_id, order_public_reference, quantity, idempotency_key)
release(offer_id, order_public_reference, idempotency_key)
expire_due_holds(now)
get_availability(offer_id)
reconcile_offer(offer_id)
```

Required Redis structures:

```text
sales:offer:{offer_id}:available              # integer/hash field
sales:offer:{offer_id}:holds                  # zset expiry ledger
sales:hold:{public_reference}                 # hash hold detail
sales:order:{public_reference}:lock           # short lock key
sales:inventory:events:{offer_id}             # optional list/stream-like audit trail
```

Required behavior:

1. Reserve is atomic.
2. Reserve is idempotent by order/idempotency key.
3. Consume is idempotent.
4. Release is idempotent.
5. Expiry cannot release already-consumed holds.
6. Redis restart recovery must be documented.
7. Redis and Postgres reconciliation must have a deterministic repair path.
8. All checkout reservations must go through `FastCheck.Sales.Inventory.ReservationLedger`.
9. No controller, LiveView, Ash resource, or worker may mutate reservation keys directly.

## 13.2 Redis Failure and Recovery Policy

Failure modes to handle:

| Failure | Required behavior |
|---|---|
| Redis unavailable during checkout | Do not accept new checkout reservations. Show temporary unavailable/manual review. |
| Redis restarts and loses volatile holds | Rebuild/reconcile from Postgres orders, checkout sessions, and issued tickets before reopening sales. |
| Redis says available but Postgres says sold | Postgres/issued-ticket count wins. Reconcile Redis downward. |
| Postgres order awaiting payment but Redis hold missing | Apply checkout expiry/payment policy. Do not issue automatically without inventory. |
| Duplicate release/consume | Must be idempotent and safe. |
| Expiry worker runs late | Expire only holds still in hold state. Never release consumed holds. |

No flash-sale checkout should proceed while inventory ledger health is unknown.

## 13.3 Redis Cache and TTL Strategy

```text
Hot active holds: Redis hash + zset, TTL/expiry ledger based on checkout policy.
Active offer display: Cachex 1–5 minutes.
Warm event offers: Redis key sales:event:{event_id}:offers, TTL 30 minutes.
Payment/webhook dedupe: Redis SETNX-style key, TTL 24 hours minimum.
Conversation hot state: Redis hash/session key, TTL based on WhatsApp session policy.
Rate limiting: Redis sorted sets or counters with short TTLs.
```

Invalidation triggers:

```text
TicketOffer create/update/disable/archive -> invalidate event offers cache and broadcast PubSub update.
Inventory reserve/consume/release/expire -> update hot availability and broadcast offer availability if needed.
Order paid/issued/cancelled/refunded -> invalidate order/admin dashboard cache.
TicketIssue revoked/refunded -> enqueue sync aggregation and invalidate ticket delivery cache.
```

---

# 14. Identities and Indexes Atlas

## 14.1 Required unique identities / DB indexes

If tenanting is accepted, add `organization_id` to relevant composite indexes and policies.

```text
TicketOffer:
  unique(event_id, name) where archived_at is null
  index(event_id, sales_enabled, starts_at, ends_at)

Order:
  unique(public_reference)
  unique(idempotency_key) where idempotency_key is not null
  index(event_id, status, inserted_at)
  index(event_id, source_channel, inserted_at)
  index(buyer_phone)
  index(expires_at, status)
  index(status, fulfillment_queued_at)

OrderLine:
  index(sales_order_id)
  index(ticket_offer_id)
  unique(sales_order_id, line_number)

CheckoutSession:
  unique(sales_order_id)
  unique(redis_hold_key) where redis_hold_key is not null
  index(status, expires_at)
  index(sales_order_id, status)

PaymentAttempt:
  unique(provider, provider_reference)
  index(sales_order_id, status)
  index(provider, status)
  index(last_verified_at)

PaymentEvent:
  unique(provider, provider_event_id)
  unique(provider, payload_hash) where provider_event_id is null
  index(provider_reference)
  index(processing_status, inserted_at)

TicketIssue:
  unique(ticket_code)
  unique(sales_order_line_id, line_item_sequence)
  unique(attendee_id) where attendee_id is not null
  index(sales_order_id)
  index(status)
  index(scanner_status)

DeliveryAttempt:
  index(sales_order_id, status)
  index(ticket_issue_id, status)
  index(provider_message_id)
  index(channel, status, inserted_at)

Conversation:
  index(phone_e164)
  index(needs_human, last_message_at)
  index(state, expires_at)

StateTransition:
  index(entity_type, entity_id, inserted_at)
  index(actor_type, actor_id, inserted_at)
  index(correlation_id)
```

## 14.2 Index rules

```text
All indexes must be created through explicit migrations.
All high-volume list pages must use indexed query paths.
No dashboard query may scan large payment, order, ticket, or transition tables during peak sales.
All partial indexes must be represented clearly in the Ash identity/index planning notes.
```

---

# 15. Performance and Scaling Review

## TicketOffer

```text
Layer: Postgres durable config + Cachex/Redis warm display cache.
Risk: stale active-offer list.
Rule: invalidate on create/update/disable.
```

## Order

```text
Layer: Postgres durable truth.
Risk: duplicate orders and invalid state transitions.
Rule: use unique public_reference/idempotency_key and explicit state transitions.
```

## CheckoutSession

```text
Layer: Postgres durable intent + Redis hot hold.
Risk: oversell if Redis atomic hold is bypassed.
Rule: all checkout reservations must go through ReservationLedger.
```

## PaymentAttempt

```text
Layer: Postgres durable payment attempt.
Risk: duplicate provider reference.
Rule: unique provider_reference and idempotent verification worker.
```

## PaymentEvent

```text
Layer: Postgres durable raw webhook + Redis dedupe.
Risk: duplicate webhook or webhook before local state exists.
Rule: store, enqueue, retry, and never drop unmatched events immediately.
```

## TicketIssue

```text
Layer: Postgres durable audit link to Attendee.
Risk: duplicate tickets from retries.
Rule: unique ticket_code and unique issue sequence per order line.
```

## DeliveryAttempt

```text
Layer: Postgres durable delivery audit + Oban retry.
Risk: Meta 24-hour window failure and hidden delivery failures.
Rule: record every attempt and fallback path.
```

## Conversation

```text
Layer: Redis hot session + Postgres checkpoints.
Risk: customer asks for ticket while payment is pending.
Rule: payment_pending state must produce reassurance message, not “ticket not found”.
```

## StateTransition

```text
Layer: Postgres append-only audit.
Risk: support disputes without timeline.
Rule: no update, no destroy, append every state change.
```

---


## 15.1 Worker Contracts

| Worker | Queue | Uniqueness | Retry rule | Must be idempotent? |
|---|---|---|---|---|
| ExpireCheckoutSessionWorker | sales_expiry | by checkout_session_id | retry until safe expiry | yes |
| PaystackWebhookWorker | payments | by payment_event_id | retry transient errors | yes |
| VerifyPaymentWorker | payments | by payment_attempt_id/provider_reference | retry provider/network failures | yes |
| IssueTicketsWorker | ticketing | by sales_order_id | retry safely forever | yes |
| SendWhatsAppTicketWorker | delivery | by delivery_attempt_id | retry provider failures | yes |
| ResendTicketWorker | delivery | by ticket_issue_id/request_id | limited retry | yes |
| EventSyncVersionAggregatorWorker | sync | by event_id/window | debounce/batch | yes |

No worker may rely on “run once” behavior for correctness.

Worker rules:

```text
Workers must load fresh state before mutating.
Workers must respect legal state transition matrices.
Workers must record or preserve correlation_id/idempotency_key where available.
Workers must not perform hidden direct status updates.
Workers must be safe under duplicate execution.
```

## 15.2 Observability and Telemetry Naming

Telemetry event names must be reserved before implementation.

Required event groups:

```text
[:fastcheck, :sales, :checkout, :reserved]
[:fastcheck, :sales, :checkout, :expired]
[:fastcheck, :sales, :payment, :webhook_received]
[:fastcheck, :sales, :payment, :verified]
[:fastcheck, :sales, :payment, :mismatch]
[:fastcheck, :sales, :ticket, :issued]
[:fastcheck, :sales, :ticket, :issue_failed]
[:fastcheck, :sales, :delivery, :sent]
[:fastcheck, :sales, :delivery, :failed]
[:fastcheck, :sales, :inventory, :reconciled]
```

Logs must include correlation IDs and must not include raw PII, access codes, authorization URLs, raw payloads, or plaintext tokens.

## 15.3 Performance and Scaling Gates

Every implementation pack must answer these questions before code is accepted:

```text
What data is hot, warm, or cold?
Does this path hit Postgres during high-concurrency checkout?
Can this read be cached in Cachex/Redis?
Does this write require a Redis-side representation?
Does this action risk overselling, duplicate payment handling, or duplicate ticket issuing?
Is this safe under duplicate Oban execution?
Is there an index for the admin/dashboard query path?
Can this be streamed or paginated instead of loaded into memory?
```

---

# 16. Ash Feature Planning Packs

These are the feature packs to create next.


## AFP-00A — State Machine and Failure Policy Finalization

Goal:

```text
Define legal transitions, terminal states, manual review behavior, payment-after-expiry rules, and failure policies.
```

Includes:

```text
Order transition matrix
CheckoutSession transition matrix
PaymentAttempt transition matrix
TicketIssue transition matrix
DeliveryAttempt transition matrix
Conversation transition matrix
payment-after-expiry policy
partial issuance policy
```

Avoid:

```text
No implementation code.
Do not let agents invent state transitions in later packs.
```

---

## AFP-00B — Security, PII, and Token Policy Finalization

Goal:

```text
Define how customer data, raw provider payloads, logs, admin/operator views, and delivery tokens are protected.
```

Includes:

```text
field-level access rules
masked admin/operator display rules
token hashing/expiry/revocation
raw payload retention
log redaction
tenant/event access rules
```

Avoid:

```text
No implementation code.
Do not expose raw provider payloads or plaintext tokens in admin/operator flows.
```

---

## AFP-00C — Inventory Recovery and Reconciliation Contract

Goal:

```text
Define Redis/Postgres recovery behavior before atomic inventory implementation.
```

Includes:

```text
reserve/consume/release contract
Redis key structures
TTL strategy
restart recovery
reconciliation workflow
oversell prevention rules
```

Avoid:

```text
No implementation code.
Do not implement checkout before this contract is accepted.
```

---

## AFP-00 — Ash Installation and Boundary Setup

Goal:

```text
Add Ash 3.x and AshPostgres dependencies, configure the Sales domain, and prove existing scanner tests still pass.
```

Includes:

```text
mix deps
config registration
Sales domain module
boundary docs
no business resources yet
```

Avoid:

```text
Do not touch scanner logic.
Do not migrate existing Events/Attendees to Ash.
```

---

## AFP-01A — Core Sales Resource Skeletons

Goal:

```text
Create TicketOffer, Order, OrderLine, and StateTransition Ash resource skeletons with migrations, identities, timestamps, and basic read actions.
```

Blocking dependency:

```text
AFP-00, AFP-00A, AFP-00B, and AFP-00C must be accepted before AFP-01A starts.
```

Includes:

```text
TicketOffer
Order
OrderLine
StateTransition
basic migrations
basic read actions
required identities and indexes
no workflow side effects
```

Avoid:

```text
No Redis calls.
No payment calls.
No ticket issuing.
No provider HTTP.
No generic update_status actions.
```

---

## AFP-01B — Checkout and Payment Resource Skeletons

Goal:

```text
Create CheckoutSession, PaymentAttempt, and PaymentEvent Ash resource skeletons with migrations, identities, indexes, and basic reads.
```

Blocking dependency:

```text
AFP-01A must be accepted before AFP-01B starts.
```

Includes:

```text
CheckoutSession
PaymentAttempt
PaymentEvent
status fields
raw payload access restrictions planned
provider reference identities
```

Avoid:

```text
No Paystack HTTP.
No webhook processing logic.
No verification logic.
No Redis mutation.
```

---

## AFP-01C — Ticket and Delivery Resource Skeletons

Goal:

```text
Create TicketIssue and DeliveryAttempt skeletons with corrected line_item_sequence identity and delivery audit fields.
```

Blocking dependency:

```text
AFP-01B must be accepted before AFP-01C starts.
```

Includes:

```text
TicketIssue
DeliveryAttempt
line_item_sequence
delivery_token_hash
scanner_status
delivery attempt tracking fields
```

Avoid:

```text
No QR rendering.
No WhatsApp sending.
No attendee creation.
No ticket issuance orchestration.
```

---

## AFP-01D — Conversation Resource Skeleton

Goal:

```text
Create Conversation skeleton for durable WhatsApp checkpoints.
```

Blocking dependency:

```text
AFP-01B must be accepted before AFP-01D starts.
```

Includes:

```text
phone_e164
wa_id
session_key
preferred_language
state
state_data
needs_human
handoff_reason
```

Avoid:

```text
No Meta API logic.
No Redis session implementation.
No conversation menu implementation.
```

---

## AFP-01E — Index and Migration Verification

Goal:

```text
Verify all Sales migrations, constraints, identities, partial indexes, and high-volume query-path indexes.
```

Blocking dependency:

```text
AFP-01A, AFP-01B, AFP-01C, and AFP-01D must be accepted before AFP-01E starts.
```

Includes:

```text
migration review
partial unique index review
rollback review
dashboard query-path index review
tenant/event index review if organization_id is accepted
```

Avoid:

```text
Do not add workflow behavior.
This is a DB correctness and review pack only.
```

---

## AFP-02 — TicketOffer Resource Pack

Goal:

```text
Implement admin-manageable sellable ticket offers.
```

Includes:

```text
create_offer
update_offer
enable_sales
disable_sales
list_active_for_event
validations
policies
cache invalidation contract
```

---

## AFP-03 — Order and OrderLine State Pack

Goal:

```text
Implement order creation, order lines, price snapshots, and order state transitions.
```

Includes:

```text
create_draft
confirm_checkout
expire_order
cancel_order
state transition audit
```

No Paystack yet.

---

## AFP-04 — CheckoutSession Pack

Goal:

```text
Persist checkout session lifecycle and connect it to Redis inventory holds.
```

Includes:

```text
session record
hold key fields
expiry state
integration boundary to ReservationLedger
```

No Lua implementation inside Ash resource.

---

## AFP-05 — PaymentAttempt and PaymentEvent Pack

Goal:

```text
Model Paystack attempts and webhook events safely in Ash.
```

Includes:

```text
payment attempt states
payment event persistence
unique provider refs
manual_review transitions
```

No HTTP client implementation inside resources.

---

## AFP-06 — TicketIssue and DeliveryAttempt Pack

Goal:

```text
Track issued tickets and delivery attempts as durable Sales audit state.
```

Includes:

```text
ticket issue records
delivery attempts
WhatsApp/email channel fields
Meta 24-hour window fields
delivery failure states
```

No QR rendering or Meta calls inside resources.

---

## AFP-07 — Conversation Resource Pack

Goal:

```text
Persist WhatsApp conversation checkpoints and human handoff state.
```

Includes:

```text
preferred_language
state
last_message_at
needs_human
Afrikaans-first defaults
number-only menu assumptions
payment_pending handling
```

Active session remains Redis.

---

## AFP-08 — Policies and Actor Model Pack

Goal:

```text
Add Ash policy rules for system/admin/operator/customer_session.
```

Includes:

```text
read/manage permissions
field restrictions
manual action permissions
system-only transitions
customer session restrictions
```

---

## AFP-09 — StateTransition Audit Pack

Goal:

```text
Make every major resource transition append an immutable audit row.
```

Includes:

```text
record_transition
list_for_entity
actor metadata
manual-review reasons
append-only guarantees
```

---

## AFP-10 — Ash/Ecto Issuance Bridge Pack

Goal:

```text
Define the safe cross-boundary orchestration pattern between Ash Sales and existing Ecto Attendees.
```

Includes:

```text
Tickets.Issuer contract
transaction/saga rules
idempotency rules
attendee creation boundary
event sync version aggregator hook
```

This is not pure Ash, but it is required for the Ash domain to be useful.

---

# 16.1 AFP to Vertical Slice Mapping

| Ash Feature Pack | Roadmap Slice |
|---|---|
| AFP-00A | VS-00A |
| AFP-00B | VS-00B |
| AFP-00C | VS-00C |
| AFP-00 | VS-01A |
| AFP-01A | VS-01B |
| AFP-01B | VS-01C |
| AFP-01C | VS-01D |
| AFP-01D | VS-01E |
| AFP-01E | VS-01G |
| AFP-08 | VS-01F |
| AFP-02 | VS-03 |
| AFP-03 | VS-05 |
| AFP-04 | VS-05 / VS-14 boundary |
| AFP-05 | VS-07A / VS-07B / VS-07C |
| AFP-06 | VS-08 / VS-09C / VS-11 boundary |
| AFP-07 | VS-18 / VS-19 boundary |
| AFP-09 | VS-00A / VS-01B / all state-changing slices |
| AFP-10 | VS-09A / VS-09B / VS-09C / VS-09D |

---

# 17. Parallelization Plan

## Can run after AFP-00 only if they do not create business resources or workflow behavior

```text
Redis Inventory Ledger planning
Paystack client boundary planning
Meta client boundary planning
Launch runbook drafts
Documentation cleanup
```

## Can run only after AFP-00A, AFP-00B, and AFP-00C are accepted

```text
AFP-01A Core Sales Resource Skeletons
AFP-01B Checkout and Payment Resource Skeletons
AFP-01C Ticket and Delivery Resource Skeletons
AFP-01D Conversation Resource Skeleton
AFP-01E Index and Migration Verification
AFP-08 Policies and Actor Model Pack
AFP-09 StateTransition Audit Pack
```

## Should not run in parallel

```text
AFP-03 Order State Pack
AFP-04 CheckoutSession Pack
AFP-05 Payment Pack
AFP-10 Ash/Ecto Issuance Bridge Pack
```

Reason:

```text
These depend on shared status vocabulary, transition rules, payment handling, checkout expiry, and issuance idempotency.
```

## Must wait until relevant resource skeletons exist

```text
AFP-02 TicketOffer requires AFP-01A
AFP-03 Order/OrderLine requires AFP-01A and AFP-00A
AFP-04 CheckoutSession requires AFP-01B, AFP-00A, and AFP-00C
AFP-05 PaymentAttempt/PaymentEvent requires AFP-01B, AFP-00A, and AFP-00B
AFP-06 TicketIssue/DeliveryAttempt requires AFP-01C, AFP-00A, and AFP-00B
AFP-07 Conversation requires AFP-01D, AFP-00A, and AFP-00B
```

## Must wait until payment + ticket issue model is stable

```text
AFP-10 Ash/Ecto Issuance Bridge
```

---

# 18. Suggested Kanban Columns for Ash Planning Packs

```text
Backlog
Ready for Planning
In Planning
Ready for Implementation
In Implementation
In Review
Blocked
Done
```

## Initial Kanban placement

### Ready for Planning

```text
AFP-00A State Machine and Failure Policy Finalization
AFP-00B Security, PII, and Token Policy Finalization
AFP-00C Inventory Recovery and Reconciliation Contract
AFP-00 Ash Installation and Boundary Setup
```

### Blocked

```text
AFP-01A Core Sales Resource Skeletons — blocked until AFP-00, AFP-00A, AFP-00B, and AFP-00C are accepted.
AFP-01B Checkout and Payment Resource Skeletons — blocked until AFP-01A.
AFP-01C Ticket and Delivery Resource Skeletons — blocked until AFP-01B.
AFP-01D Conversation Resource Skeleton — blocked until AFP-01B.
AFP-01E Index and Migration Verification — blocked until AFP-01A, AFP-01B, AFP-01C, and AFP-01D.
AFP-02 TicketOffer Resource Pack — blocked until AFP-01A.
AFP-03 Order and OrderLine State Pack — blocked until AFP-00A and AFP-01A.
AFP-04 CheckoutSession Pack — blocked until AFP-00A, AFP-00C, and AFP-01B.
AFP-05 PaymentAttempt and PaymentEvent Pack — blocked until AFP-00A, AFP-00B, and AFP-01B.
AFP-06 TicketIssue and DeliveryAttempt Pack — blocked until AFP-00A, AFP-00B, and AFP-01C.
AFP-07 Conversation Resource Pack — blocked until AFP-00A, AFP-00B, and AFP-01D.
AFP-08 Policies and Actor Model Pack — blocked until AFP-00B and resource skeleton scope is stable.
AFP-09 StateTransition Audit Pack — blocked until AFP-00A and StateTransition skeleton exists.
AFP-10 Ash/Ecto Issuance Bridge Pack — blocked until payment, ticket issue, and attendee-origin contracts are stable.
```

### Backlog

```text
Provider client implementation packs
Redis inventory implementation packs
WhatsApp implementation packs
Admin UI implementation packs
Launch runbook packs
```

---

# 19. Subagent Recommendations

## Ash Domain Agent

Owns:

```text
AFP-00
AFP-01A
AFP-01B
AFP-01C
AFP-01D
AFP-01E
AFP-02
AFP-03
AFP-05
AFP-06
AFP-07
AFP-08
AFP-09
```

Must know:

```text
Ash 3.x
AshPostgres
Phoenix context boundaries
stateful workflows
policies
```

## Integration Boundary Agent

Owns:

```text
Paystack plain modules
Meta plain modules
Redis inventory service
Oban orchestration boundaries
```

Must not:

```text
put provider calls inside Ash resources
put Redis Lua inside Ash resources
```

## Ticket Issuance Bridge Agent

Owns:

```text
AFP-10
Tickets.Issuer contract
Ash/Ecto transaction or saga pattern
Attendee creation boundary
idempotency
```

Must know:

```text
existing Attendees context
existing scan eligibility rules
mobile sync version invalidation
```

## QA/Invariant Agent

Owns:

```text
state transition tests
policy tests
idempotency tests
invalid transition tests
manual review edge cases
```

---


# 19.1 Required Test Matrix

Every implementation pack must define tests before code is accepted.

Required test groups:

1. Ash resource validation tests
2. Ash policy tests
3. State transition allow/deny tests
4. Payment verification edge-case tests
5. Duplicate webhook tests
6. Payment-after-expiry tests
7. Redis reserve/consume/release concurrency tests
8. Checkout expiry tests
9. Ticket issuance idempotency tests
10. Partial ticket issuance failure tests
11. Attendee origin protection tests
12. Scanner visibility tests for revoked/refunded tickets
13. Delivery fallback tests
14. PII/log redaction tests
15. Oban retry/idempotency tests
16. Tenant/event isolation tests if organization_id is accepted
17. Admin manual-review audit reason tests
18. Cache invalidation tests for active offers and ticket revocation

No pack should be marked implementation-ready without explicit success-path and failure-path tests.

---

# 20. Success Criteria for the Ash Planning Layer

The Ash plan is ready for implementation feature packs when these are confirmed:

```text
Sales domain module name is final.
Resource list is final.
Table names are final.
Action names are final.
State enums are final.
Policy actor model is final.
Identities and indexes are final.
Non-Ash modules are explicitly listed.
Cross-boundary ticket issuance pattern is explicit.
Provider clients stay outside Ash resources.
Redis scripts stay outside Ash resources.
DeliveryAttempt is accepted as a first-class resource.
CheckoutSession states are explicit.
Payment-after-expiry policy is explicit.
TicketIssue line_item_sequence identity is explicit.
Redis ledger contract and recovery policy are explicit.
Attendee origin protection is explicit.
Security, PII, and token policy is explicit.
Worker idempotency contracts are explicit.
Required test matrix is explicit.
WhatsApp-first production launch intent is explicit.
Temporary bridge entrypoints are clearly separated from the intended customer sales channel.
```

---

# 21. Final Recommendation

Use Ash 3.x as the durable Sales domain layer, not as a replacement for the existing FastCheck runtime.

The right split is:

```text
Ash:
  durable sales state, named actions, policies, validations, audit resources

Ecto existing code:
  Events, Attendees, scanner, Tickera sync, mobile API

Plain modules:
  Redis inventory, Paystack, Meta Cloud API, QR, delivery token, workers

Explicit orchestration:
  Tickets.Issuer coordinates Ash Sales + Ecto Attendees
```

The strongest recommendation in this document is to keep the strategic product direction clear: FastCheck Sales is WhatsApp-first in production, using Meta Cloud API for the customer conversation/delivery layer and Paystack for payment.

The second strongest recommendation is to make `DeliveryAttempt` a first-class Ash resource from the start. It is needed for Meta 24-hour delivery handling, retries, fallback, support, and audit.

The third strongest recommendation is to treat state transition matrices, payment-after-expiry handling, Redis recovery, and ticket issuance idempotency as blocking architecture, not later hardening. If those are left vague, the system may look clean while still failing under real money, retries, expired holds, refunds, or scanner sync.

Build the Sales core first, but do not lose the product direction: the intended customer sales channel is WhatsApp → Paystack → verified ticket issuance → FastCheck scanner acceptance.

