# FastCheck Sales Feature Planning Pack — VS-18 WhatsApp Number-Only Conversation Flow

**Pack ID:** `0039_VS-18_whatsapp-number-only-conversation-flow`  
**Slice:** `VS-18`  
**Slice name:** WhatsApp Number-Only Conversation Flow  
**Version:** `v1.0`  
**Date:** 2026-06-13  
**Status:** Implementation-ready conversation-flow slice, dependent on VS-17 and VS-05  
**Primary area:** WhatsApp / Conversation State / Sales Checkout Adapter  
**Repo truth:** `JCSchoeman96/FastCheckin`  
**Repository path:** `docs/fastcheck_sales/feature_packs/0039_VS-18_whatsapp-number-only-conversation-flow/`  
**Source docs:** `docs/fastcheck_sales/SOURCE_DOCS/FastCheck_Sales_Ash_Atlas_Planning_Pack_v0.2.3_HARDENED.md`, `docs/fastcheck_sales/SOURCE_DOCS/FastCheck_Sales_Vertical_Slice_Roadmap_v1.1.3_HARDENED.md`  
**Normalization:** Batch `0038_0040`, normalized 2026-06-14  
**Depends on:** VS-17, VS-05, VS-03, VS-00A, VS-00B, VS-01E, VS-01F, VS-16  
**Blocks:** VS-19, VS-20, VS-22, VS-23C  

---

## 1. Purpose

Implement the **WhatsApp number-only conversation state machine** that guides customers through a simple Afrikaans-first ticket-buying flow.

This slice owns the conversational menu and state transitions only. It must not become payment authority, inventory authority, or ticket issuance authority.

Core principle:

```text
WhatsApp is an interface layer.
Sales core owns checkout/order/inventory state.
Paystack owns provider payment interaction.
Tickets.Issuer owns issuing.
Existing FastCheck scanner remains the runtime ticket authority.
```

### Repo-alignment guardrail — VS-05A is not a dependency

```text
VS-18 must depend on the shared Sales checkout core from VS-05.
VS-18 must not depend on VS-05A.
VS-05A owns selected secondary Sales entrypoints such as admin-assisted or web checkout paths.
WhatsApp-first conversation flow must remain a channel adapter over the same VS-05 Sales core, not over secondary entrypoint code.
```

---

## 2. FastCheckin Current-State Truth

Use the current FastCheckin backend shape:

```text
Application root: FastCheck
Web root: FastCheckWeb
Existing route separation: browser/dashboard/api/mobile pipelines
Existing Redis connection: FastCheck.Redix through FastCheck.Redis.Connection
Existing request metadata: FastCheckWeb.Plugs.LoggerMetadata
WhatsApp outbound provider boundary from VS-16
WhatsApp inbound webhook/session boundary from VS-17
Sales durable Conversation resource from VS-01E
Sales order/checkout core from VS-05
```

No existing WhatsApp conversation flow exists in FastCheckin at the time of this pack. Implement this as a clean new module set under `lib/fastcheck/messaging/whatsapp/` and only persist durable checkpoints through approved Sales Conversation actions.

---

## 3. Ultimate Outcome

After VS-18:

```text
Customer sends WhatsApp message
  -> VS-17 verifies/dedupes/normalizes inbound message
  -> WhatsAppInboundWorker calls ConversationStateMachine.handle_inbound/2
  -> state machine resolves the next state and response
  -> Redis hot session is updated
  -> Sales.Conversation durable checkpoint is updated
  -> VS-16 outbound client sends safe text/menu response
```

The customer can navigate using numbers only:

```text
1, 2, 3, 0, #, help, stop
```

The flow supports:

```text
language selection
main menu
event selection
ticket offer selection
quantity selection
buyer name capture
email capture optional/skip
order confirmation
handoff to checkout/payment link creation boundary
payment_pending reassurance state
cancel/restart/help paths
human handoff state
```

---

## 4. Scope

### In scope

```text
Afrikaans-first, English-second number-only menu copy.
Conversation state-machine module.
Inbound text normalization and command handling.
Redis hot session update contract.
Durable Sales.Conversation checkpoint update contract.
Menu rendering via MessageBuilder from VS-16.
Approved Sales core calls for event/offer lookup and checkout start.
Payment-pending customer response rules.
Rate-limit and abuse posture inherited from VS-17.
Tests for valid/invalid navigation, restart/cancel/help, state recovery, and no authority bypass.
```

### Out of scope

```text
No Meta inbound webhook verification. That is VS-17.
No Meta provider client implementation. That is VS-16.
No Paystack initialization implementation. That is VS-06B / VS-19 boundary usage.
No Paystack webhook/verification. That is VS-07A/B/C.
No ticket issuing. That is VS-09A-D.
No DeliveryAttempt lifecycle. That starts in VS-19/VS-20.
No secure ticket page implementation. That is VS-11.
No admin manual review UI. That is VS-13.
No refund/revocation behavior. That is VS-15A/B.
No scanner/mobile API changes.
```

---

## 5. Recommended Files

Create or extend only these focused areas:

```text
lib/fastcheck/messaging/whatsapp/conversation_state_machine.ex
lib/fastcheck/messaging/whatsapp/menu_renderer.ex
lib/fastcheck/messaging/whatsapp/input_normalizer.ex
lib/fastcheck/messaging/whatsapp/copy.ex
lib/fastcheck/messaging/whatsapp/flow_result.ex
lib/fastcheck/workers/whatsapp_inbound_worker.ex                 # extend from VS-17 only
lib/fastcheck/sales/conversation.ex                              # only approved Ash/Sales action additions
lib/fastcheck/sales.ex                                           # only if domain exposes needed actions

test/fastcheck/messaging/whatsapp/conversation_state_machine_test.exs
test/fastcheck/messaging/whatsapp/input_normalizer_test.exs
test/fastcheck/messaging/whatsapp/menu_renderer_test.exs
test/fastcheck/workers/whatsapp_inbound_worker_test.exs
```

Do not modify scanner, Attendee, Paystack, TicketIssue, DeliveryAttempt, or checkout internals except through approved public interfaces.

---

## 6. Conversation State Machine

Minimum states:

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

Minimum legal transitions:

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
cancelled -> terminal unless restart creates/resumes a new session
expired -> terminal unless start_or_resume creates a new session
completed -> terminal unless explicit resend/support flow starts later
```

Command rules:

```text
0 = back or main menu, depending state
# = restart / main menu
help = support/help response
stop = cancel conversation and stop non-essential session responses
1..9 = menu selection
free text is accepted only in buyer name/email states
invalid input returns the current menu with concise correction
```

---

## 7. Afrikaans-First Copy Contract

Default language:

```text
af
```

Language selection prompt:

```text
Welkom by FastCheck Tickets.
1. Afrikaans
2. English
```

Afrikaans tone:

```text
kort
vriendelik
duidelik
number-only
no slang that can confuse older customers
```

English tone:

```text
short
friendly
plain language
number-only
```

Copy rules:

```text
Do not include raw DB ids.
Do not include raw Paystack access_code.
Do not include raw provider payloads.
Do not include full internal error messages.
Do not include delivery-token hashes.
Do not expose ticket URLs before payment verification/issuance.
```

---

## 8. Approved Sales-Core Boundaries

The conversation state machine may call only approved facade/service functions.

Allowed examples:

```text
FastCheck.Sales.list_whatsapp_sellable_events(actor)
FastCheck.Sales.list_active_offers_for_event(event_id, actor)
FastCheck.Sales.start_whatsapp_checkout(params, actor)
FastCheck.Sales.get_order_payment_state(order_public_reference, actor)
FastCheck.Sales.mark_conversation_checkpoint(conversation_id, attrs, actor)
```

If these do not exist yet, VS-18 must define the contract and fail tests until VS-05 exposes them.

Forbidden:

```text
Do not query TicketOffer/Order/CheckoutSession with raw Repo from the WhatsApp flow.
Do not mutate Redis inventory directly.
Do not call Paystack directly.
Do not issue tickets.
Do not create Attendees.
Do not create DeliveryAttempt rows.
Do not bypass Ash/Sales policies.
```

---

## 9. Redis Session Contract

Redis hot session from VS-17 should hold ephemeral state for fast inbound handling.

Recommended key:

```text
fastcheck:whatsapp:session:{wa_id}
```

Recommended hash fields:

```text
conversation_id
phone_e164
wa_id
state
preferred_language
selected_event_id
selected_offer_id
quantity
buyer_name
buyer_email
sales_order_id
order_public_reference
last_message_id
last_message_at
expires_at
version
```

TTL:

```text
24h for active WhatsApp session window
extend on inbound customer message
shorter 15m–30m TTL for incomplete checkout-start state if no meaningful progress
```

Rules:

```text
Redis is hot state only.
Postgres/Sales.Conversation is durable checkpoint.
If Redis is missing but durable checkpoint exists, rebuild safe session summary from Postgres.
If Redis and Postgres conflict, durable payment/order/ticket state wins.
Do not store raw provider payloads in Redis session.
Do not store Paystack authorization_url in session unless policy explicitly allows it; prefer order/payment state reference.
Do not store ticket delivery tokens in Redis session.
```

---

## 10. Payment-Pending Message Rules

The conversation must never mislead customers when payment state is uncertain.

Required behavior:

```text
If order is awaiting_payment: remind customer to complete payment using the existing approved payment link.
If payment webhook received but verification pending: say payment is being confirmed.
If payment verified and fulfillment queued: say payment is confirmed and tickets are being prepared.
If ticket issued but delivery failed: say tickets are ready and support/delivery is being retried.
If manual_review: say support is checking the order.
Never say “no payment found” when durable PaymentAttempt/PaymentEvent says payment may exist.
```

---

## 11. Idempotency and Dedupe

VS-17 handles provider-level inbound dedupe. VS-18 must still be safe under duplicate worker execution.

Rules:

```text
handle_inbound/2 must be deterministic for the same conversation version and message id.
If message already processed, return idempotent no-op or same outbound response key.
State updates must use optimistic versioning or durable idempotency metadata where available.
Duplicate checkout confirmation must not create duplicate orders.
Duplicate quantity/name/email messages must not advance state twice in unsafe ways.
```

---

## 12. RED/GREEN Test Plan

### RED tests first

```text
RED: new inbound message starts selecting_language or main_menu according to locale policy.
RED: language selection 1 sets preferred_language=af.
RED: language selection 2 sets preferred_language=en.
RED: main_menu only accepts configured number options.
RED: invalid menu input repeats the current menu with a correction.
RED: event selection uses approved Sales event listing facade, not raw Repo.
RED: offer selection uses approved Sales offer listing facade, not raw Repo.
RED: quantity validates positive integer and max_per_order boundary.
RED: buyer name accepts free text only in collecting_buyer_name.
RED: email can be skipped if policy allows or validated when supplied.
RED: confirm_order calls approved checkout boundary once.
RED: duplicate confirm message does not create duplicate checkout/order.
RED: payment_pending copy does not say payment/ticket does not exist when durable payment state is pending.
RED: Redis session loss rebuilds safe state from Sales.Conversation checkpoint.
RED: stop/cancel moves to cancelled and prevents checkout start.
RED: help returns support guidance without changing payment/order state.
RED: customer_session cannot broad-read Sales resources.
RED: logs do not include phone_e164, wa_id, buyer_email, buyer_name, raw inbound payload, payment URL, or ticket token.
RED: no Paystack, TicketIssue, Attendee, DeliveryAttempt, scanner, or Redis inventory behavior is called.
```

### GREEN targets

```text
GREEN: WhatsApp number-only flow can guide a customer to a checkout-start boundary.
GREEN: Flow is recoverable from Redis loss using durable conversation checkpoint.
GREEN: Duplicate worker execution is safe.
GREEN: Afrikaans-first copy is consistent and customer-safe.
GREEN: VS-19 can attach Paystack/payment/ticket delivery behavior without rewriting the menu core.
```

---

## 13. Failure Modes

| Failure | Required behavior |
|---|---|
| Redis unavailable | Do not lose durable checkpoint; return retryable worker error or safe support message depending stage. |
| Sales event/offers unavailable | Return friendly “no tickets available right now” and do not create order. |
| Selected offer sold out | Return offer unavailable and move back to offer selection. |
| Invalid quantity | Repeat quantity prompt with max/min rule. |
| Checkout boundary returns inventory unavailable | Return sold-out/unavailable message, no Paystack. |
| Duplicate inbound worker | Idempotent result; no duplicate order/checkout. |
| Customer sends free text at menu | Repeat number-only prompt. |
| Customer sends stop | Cancel session and stop sales flow. |
| Payment state uncertain | Reassure and check durable state; do not say no payment exists. |
| Conversation checkpoint corrupt/missing | Start safe main menu or handoff to manual_review; do not guess paid state. |

---

## 14. Performance and Scaling Review

### Data placement

```text
Hot: Redis WhatsApp session hash, 24h TTL.
Warm: Cachex/Redis active event/offers list if VS-03/VS-05 exposes cached facade.
Cold: Sales.Conversation, Sales.Order, Sales.CheckoutSession in Postgres/Ash.
```

### Redis structures

```text
session: Redis hash fastcheck:whatsapp:session:{wa_id}
dedupe: Redis SET NX EX from VS-17
rate limit: Redis sorted set/counter if shared backend enabled
conversation activity: optional Redis list for recent session diagnostics, capped TTL
```

### Scaling rules

```text
Do not query all events/offers on every message if cached facade exists.
Do not load large order history for a phone number.
Do not scan conversations table by phone without index.
Do not store raw payloads in Redis.
Do not perform Paystack HTTP in the conversation state machine.
Keep state-machine handling sub-100ms excluding outbound provider call.
```

### Required indexes

```text
sales_conversations(phone_e164)
sales_conversations(wa_id)
sales_conversations(session_key)
sales_conversations(state, expires_at)
sales_conversations(needs_human, last_message_at)
sales_orders(whatsapp_conversation_id)
sales_orders(public_reference)
sales_orders(buyer_phone, inserted_at)
sales_ticket_offers(event_id, sales_enabled, starts_at, ends_at)
```

### PubSub

```text
Broadcast admin visibility only if VS-12/VS-21B convention exists.
Do not broadcast customer PII.
No LiveView polling should be introduced.
```

---

## 15. Security and PII

PII fields:

```text
phone_e164
wa_id
buyer_name
buyer_email
raw inbound text
```

Rules:

```text
Mask phone/email in logs and admin previews.
Do not log raw inbound payloads.
Do not log full message body by default.
Do not include authorization_url in logs.
Do not include ticket URLs/tokens in logs.
Keep raw Meta webhook payload access restricted to system/admin debug policy from VS-00B/VS-17.
Operator views must not show raw payload by default.
```

---

## 16. Telemetry

Recommended events:

```text
[:fastcheck, :whatsapp, :conversation, :started]
[:fastcheck, :whatsapp, :conversation, :state_changed]
[:fastcheck, :whatsapp, :conversation, :invalid_input]
[:fastcheck, :whatsapp, :conversation, :checkout_requested]
[:fastcheck, :whatsapp, :conversation, :checkout_rejected]
[:fastcheck, :whatsapp, :conversation, :payment_pending_response]
[:fastcheck, :whatsapp, :conversation, :cancelled]
[:fastcheck, :whatsapp, :conversation, :manual_review]
```

Metadata:

```text
conversation_id
state_from
state_to
event_id if selected
offer_id if selected
source_channel=whatsapp
correlation_id
```

Forbidden metadata:

```text
phone_e164
wa_id
buyer_email
buyer_name
raw text
payment URL
ticket token
```

---

## 17. TOON Coding-Agent Prompt

| Field | Content |
|---|---|
| Task | Implement VS-18 WhatsApp Number-Only Conversation Flow in `JCSchoeman96/FastCheckin`. |
| Objective | Add the Afrikaans-first WhatsApp conversation state machine that guides customers through event, offer, quantity, buyer detail, confirmation, and checkout-start states while keeping WhatsApp as an interface layer over the Sales core. |
| Output | `lib/fastcheck/messaging/whatsapp/conversation_state_machine.ex`, `menu_renderer.ex`, `input_normalizer.ex`, `copy.ex`, `flow_result.ex`, minimal extension to `FastCheck.Workers.WhatsAppInboundWorker`, Sales.Conversation checkpoint action usage, and tests for state transitions, invalid inputs, Redis recovery, duplicate workers, checkout boundary calls, PII/log redaction, and forbidden side effects. |
| Note | Use existing FastCheckin module roots: `FastCheck` and `FastCheckWeb`. Depend on VS-17 inbound normalization/session/dedupe and VS-16 outbound message builder/client. Conversation hot state belongs in Redis hash `fastcheck:whatsapp:session:{wa_id}` with ~24h TTL; durable checkpoint belongs in `FastCheck.Sales.Conversation`. Data layers: hot Redis session, warm cached active events/offers, cold Ash/Postgres conversation/order state. Required indexes: `sales_conversations(phone_e164)`, `sales_conversations(wa_id)`, `sales_conversations(state, expires_at)`, `sales_orders(whatsapp_conversation_id)`, `sales_ticket_offers(event_id, sales_enabled, starts_at, ends_at)`. Do not query raw Repo from the WhatsApp flow; use approved Sales facades. Do not call Paystack, mutate Redis inventory, issue tickets, create Attendees, create DeliveryAttempt rows, or change scanner/mobile APIs. Payment-pending messages must never say no payment/ticket exists when durable payment state may exist. Logs must redact phone, wa_id, buyer_email, buyer_name, raw text, payment URLs, and ticket tokens. |
| Success | A duplicate-safe number-only WhatsApp flow can take a customer to the checkout-start boundary, recover from Redis session loss using durable checkpoints, keep all authority in the Sales/payment/ticketing services, and prepare VS-19 to connect Paystack links and ticket delivery. |

---

## 18. Copy-Paste Prompt for Coding Agent

```text
You are implementing FastCheck Sales VS-18 — WhatsApp Number-Only Conversation Flow in JCSchoeman96/FastCheckin.

Goal:
Create the Afrikaans-first number-only WhatsApp conversation state machine. It must sit on top of VS-17 inbound webhook/session/dedupe and VS-16 outbound client/message builder. It must call the Sales core through approved facades only.

Implement:
1. FastCheck.Messaging.WhatsApp.ConversationStateMachine.handle_inbound/2.
2. FastCheck.Messaging.WhatsApp.InputNormalizer for number/help/stop/free-text normalization.
3. FastCheck.Messaging.WhatsApp.MenuRenderer for Afrikaans-first and English menu copy.
4. FastCheck.Messaging.WhatsApp.Copy for reusable localized text.
5. FastCheck.Messaging.WhatsApp.FlowResult to describe response, next state, checkpoint changes, and outbound message intent.
6. Minimal extension to FastCheck.Workers.WhatsAppInboundWorker so it calls the state machine after VS-17 verification/dedupe.
7. Durable Sales.Conversation checkpoint updates through approved Sales actions.
8. Redis hot session update through VS-17 SessionStore.

States:
new, selecting_language, main_menu, selecting_event, selecting_ticket_type, collecting_quantity, collecting_buyer_name, collecting_email, confirming_order, awaiting_payment, payment_pending, payment_received, ticket_issued, completed, manual_review, cancelled, expired.

Rules:
- Default language is Afrikaans.
- Number-only menu navigation.
- Free text only allowed for buyer name/email states.
- `0` goes back/main menu.
- `#` restarts/main menu.
- `help` returns support guidance.
- `stop` cancels the session.
- Invalid input repeats current menu with a concise correction.
- Confirming an order must call an approved Sales checkout boundary once and must be idempotent.
- Payment-pending messages must not say payment/ticket does not exist when durable payment state may exist.

Do not:
- implement Meta webhook verification; VS-17 owns it
- implement Meta outbound HTTP client; VS-16 owns it
- call Paystack directly
- mutate Redis inventory
- issue tickets
- create Attendees
- create DeliveryAttempt rows
- access Sales resources through raw Repo queries
- change scanner/mobile APIs
- log phone, wa_id, buyer name/email, raw message text, payment URLs, ticket URLs, tokens, or raw payloads

Tests:
Write RED tests first for language selection, invalid input, event selection, offer selection, quantity validation, buyer detail capture, checkout confirmation idempotency, Redis session recovery from durable checkpoint, payment-pending reassurance copy, stop/cancel/help commands, policy boundaries, no forbidden side effects, and log redaction.
```

---

## 19. Human Review Checklist

```text
[ ] Implementation is in FastCheckin repo.
[ ] WhatsApp flow is number-only except buyer name/email collection.
[ ] Afrikaans is default language.
[ ] Durable checkpoint uses Sales.Conversation, not only Redis.
[ ] Redis session has TTL and contains no raw provider payload/token.
[ ] Event/offer lookup uses approved Sales facades.
[ ] Checkout start uses approved Sales checkout boundary.
[ ] Duplicate confirm message cannot create duplicate orders.
[ ] Payment-pending copy is safe and non-misleading.
[ ] No Paystack HTTP call is inside conversation state machine.
[ ] No ticket issuing occurs.
[ ] No Attendee mutation occurs.
[ ] No DeliveryAttempt rows are created.
[ ] No Redis inventory mutation occurs.
[ ] No scanner/mobile API changes occur.
[ ] Logs redact phone, wa_id, buyer email/name, raw text, payment URLs, and ticket tokens.
[ ] Tests cover invalid input, stop/help/restart, Redis recovery, idempotency, and forbidden side effects.
```

---

## 20. Next Slice

```text
VS-19 — WhatsApp Payment and Ticket Flow
```
