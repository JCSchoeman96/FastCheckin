# FastCheck Sales Feature Planning Pack — VS-19 WhatsApp Payment and Ticket Flow

**Pack ID:** `0040_VS-19_whatsapp-payment-and-ticket-flow`  
**Slice:** `VS-19`  
**Slice name:** WhatsApp Payment and Ticket Flow  
**Version:** `v1.0`  
**Date:** 2026-06-13  
**Status:** Implementation-ready planning pack after VS-07C, VS-11, and VS-18  
**Primary area:** WhatsApp / Sales / Paystack handoff / Ticket delivery handoff  
**Repo truth:** `JCSchoeman96/FastCheckin`  
**Repository path:** `docs/fastcheck_sales/feature_packs/0040_VS-19_whatsapp-payment-and-ticket-flow/`  
**Source docs:** `docs/fastcheck_sales/SOURCE_DOCS/FastCheck_Sales_Ash_Atlas_Planning_Pack_v0.2.3_HARDENED.md`, `docs/fastcheck_sales/SOURCE_DOCS/FastCheck_Sales_Vertical_Slice_Roadmap_v1.1.3_HARDENED.md`  
**Normalization:** Batch `0038_0040`, normalized 2026-06-14  
**Depends on:** VS-07C, VS-11, VS-18, VS-05, VS-06B, VS-06C, VS-07A, VS-07B, VS-09D, VS-12, VS-15A, VS-16, VS-17  
**Blocks:** VS-20, VS-22, VS-23C, WhatsApp-first production launch  

---

## 1. Purpose

Connect the WhatsApp number-only conversation flow to the already-built Sales core:

```text
WhatsApp inbound message
  -> VS-18 conversation state machine
  -> approved Sales checkout/order service
  -> Paystack transaction initialization from backend
  -> customer receives Paystack authorization link by WhatsApp
  -> payment-pending reassurance messages
  -> verified payment and ticket issuance already handled by VS-07C/VS-09D
  -> customer can request/get secure ticket link after issue
```

This slice is the first WhatsApp customer journey that touches real checkout/payment state, but it must still remain an **interface layer**.

Non-negotiable rule:

```text
WhatsApp does not own inventory authority.
WhatsApp does not own payment authority.
WhatsApp does not issue tickets.
WhatsApp does not mutate scanner-visible validity.
```

---

## 2. FastCheckin Repo Truth

Use the current FastCheckin architecture as the boundary:

```text
Router already separates API/browser/mobile pipelines.
Runtime config already reads secrets from environment variables.
Redis is already supervised through FastCheck.Redix.
Logger metadata already exists for request tracing.
Existing scanner/mobile/Attendee logic must remain untouched.
```

Use the Sales roadmap truth:

```text
Primary production channel is whatsapp_first_paid_core.
WhatsApp-first production launch requires VS-16 through VS-20 and VS-23C.
No channel may bypass Redis inventory, Paystack verification, idempotent issuance, DeliveryAttempt audit, or scanner-safe revocation.
```

---

## 3. Ultimate Outcome

After VS-19:

```text
A customer can start or resume a WhatsApp purchase conversation.
The customer can select event/offer/quantity through number-only menus.
The system creates/uses the approved Sales checkout path.
The system initializes Paystack through the backend boundary.
The customer receives a safe Paystack authorization link.
The conversation state moves to awaiting_payment/payment_pending.
The customer can ask about payment/ticket status without getting false "not found" responses.
When tickets are already issued, the conversation can provide the secure ticket page link.
All delivery attempts are audited or queued according to the DeliveryAttempt contract.
No ticket is issued directly from WhatsApp code.
```

---

## 4. Scope

### In scope

```text
Connect VS-18 selected event/offer/quantity states to approved Sales checkout service.
Start or resume an existing checkout/order for the WhatsApp conversation.
Initialize Paystack transaction through approved payment boundary.
Send Paystack authorization URL through VS-16 outbound client.
Persist/advance Sales.Conversation checkpoint state.
Render Afrikaans-first payment instructions and payment-pending reassurance.
Allow "check status" and "send my ticket" style menu actions.
When TicketIssue is already issued, return secure ticket page link from VS-11.
Create/queue DeliveryAttempt audit records for WhatsApp payment-link and ticket-link messages if DeliveryAttempt is already available.
Record StateTransition entries for state changes.
Add tests for duplicate messages, duplicate worker execution, payment-pending behavior, issued-ticket retrieval, and boundary restrictions.
```

### Out of scope

```text
No Meta inbound webhook implementation. That is VS-17.
No basic number-only menu implementation. That is VS-18.
No Meta outbound client implementation. That is VS-16.
No Paystack HTTP client implementation. That is VS-06A.
No payment verification implementation. That is VS-07B/VS-07C.
No ticket issuance implementation. That is VS-09A through VS-09D.
No secure ticket page implementation. That is VS-11.
No Meta 24-hour template/fallback policy. That is VS-20.
No refund/revocation implementation. That is VS-15A/VS-15B.
No scanner/mobile API changes.
No direct Redis inventory mutation.
```

---

## 5. Recommended Files

Create or extend these files only if they match existing project style:

```text
lib/fastcheck/messaging/whatsapp/payment_flow.ex
lib/fastcheck/messaging/whatsapp/payment_status_renderer.ex
lib/fastcheck/messaging/whatsapp/ticket_link_renderer.ex
lib/fastcheck/messaging/whatsapp/flow_result.ex
lib/fastcheck/workers/whatsapp_payment_flow_worker.ex
lib/fastcheck/workers/send_whatsapp_payment_link_worker.ex
lib/fastcheck/workers/send_whatsapp_ticket_link_worker.ex
lib/fastcheck/sales/conversation.ex
lib/fastcheck/sales/delivery_attempt.ex
lib/fastcheck_web/controllers/webhooks/whatsapp_controller.ex

test/fastcheck/messaging/whatsapp/payment_flow_test.exs
test/fastcheck/messaging/whatsapp/payment_status_renderer_test.exs
test/fastcheck/workers/whatsapp_payment_flow_worker_test.exs
test/fastcheck/workers/send_whatsapp_payment_link_worker_test.exs
test/fastcheck/workers/send_whatsapp_ticket_link_worker_test.exs
```

Do not modify scanner, Attendee, Tickera reconciliation, or mobile sync unless a test proves an accidental coupling; then stop and escalate.

---

## 6. Domain Model

### Durable resources touched

```text
FastCheck.Sales.Conversation
FastCheck.Sales.Order
FastCheck.Sales.OrderLine
FastCheck.Sales.CheckoutSession
FastCheck.Sales.PaymentAttempt
FastCheck.Sales.TicketIssue
FastCheck.Sales.DeliveryAttempt
FastCheck.Sales.StateTransition
```

### Non-Ash/plain modules touched

```text
FastCheck.Messaging.WhatsApp.PaymentFlow
FastCheck.Messaging.WhatsApp.MessageBuilder
FastCheck.Messaging.WhatsApp.Client
FastCheck.Messaging.WhatsApp.SessionStore
FastCheck.Messaging.WhatsApp.Dedupe
FastCheck.Payments.Paystack.TransactionInitializer
FastCheck.Tickets.DeliveryToken
```

### External systems

```text
Meta Cloud API outbound send endpoint
Paystack transaction initialization boundary
Redis conversation hot state
Redis inbound idempotency/dedupe keys
Postgres durable Sales state
```

---

## 7. State Machine Additions

### Conversation states used in VS-19

```text
confirming_order -> awaiting_payment
awaiting_payment -> payment_pending
awaiting_payment -> payment_received
payment_pending -> payment_received
payment_received -> ticket_issued
payment_received -> manual_review
ticket_issued -> completed
```

### Required message behavior

| Current durable state | Customer message | Required response |
|---|---|---|
| checkout created but payment link not sent | any status request | send or re-send payment link if safe |
| awaiting_payment | "status" / menu option | show payment link and payment instructions |
| payment_pending | "status" | reassure that payment is being checked; do not say no ticket exists |
| paid_verified / fulfillment_queued | "ticket" | say payment received, ticket is being prepared |
| ticket_issued | "ticket" | send secure ticket page link |
| manual_review | any status request | human/support handoff message |
| expired/cancelled/refunded | status request | explain safe terminal state; do not issue ticket |

### Forbidden transitions

```text
WhatsApp code must not mark paid_verified.
WhatsApp code must not mark ticket_issued.
WhatsApp code must not mark refunded.
WhatsApp code must not mark revoked.
WhatsApp code must not create Attendee rows.
WhatsApp code must not consume Redis inventory directly.
```

---

## 8. Payment Link Handoff Contract

Payment link creation must flow through backend services:

```text
PaymentFlow.confirm_checkout_from_conversation(conversation_id, input)
  -> Sales checkout facade validates selected event/offer/quantity
  -> Inventory reservation is handled by Sales checkout core / ReservationLedger
  -> Order/CheckoutSession created or resumed idempotently
  -> Paystack.TransactionInitializer initializes provider transaction
  -> PaymentAttempt stored with provider_reference/access_code/authorization_url
  -> WhatsApp payment link message queued/sent
  -> Conversation moves to awaiting_payment/payment_pending
```

Rules:

```text
Do not initialize Paystack for expired/cancelled/manual_review order unless approved recovery path exists.
Do not generate a new order for duplicate WhatsApp message if an active checkout already exists.
Do not send more than one fresh payment link per idempotency window unless user explicitly asks to resend.
Do not log authorization_url or access_code.
Do not include provider raw payloads in conversation state_data.
```

---

## 9. Ticket Link Handoff Contract

Ticket link delivery must use the secure ticket page from VS-11.

```text
PaymentFlow.send_ticket_link_if_issued(conversation_id, opts)
  -> load current Conversation/Order/TicketIssue
  -> verify ticket_issued / issued state
  -> generate or reuse safe delivery token according to VS-08/VS-11 policy
  -> send secure ticket page URL through WhatsApp outbound client
  -> create/mark DeliveryAttempt if delivery audit is active
```

Rules:

```text
Never send raw QR payload in WhatsApp text if secure ticket page is the approved delivery surface.
Never send ticket link for revoked/refunded/cancelled TicketIssue.
Never expose delivery_token_hash.
If ticket is not issued yet but payment is verified, respond with preparation message.
If payment is not verified, respond with payment-pending/payment-link message.
```

---

## 10. Idempotency and Deduplication

Required idempotency keys:

```text
whatsapp inbound provider_message_id
conversation_id + state + selected option + message timestamp bucket
conversation_id + order_public_reference + payment_link_send
conversation_id + ticket_issue_id + ticket_link_send
payment_attempt_id + provider_reference
```

Required behavior:

```text
Duplicate inbound message must not create duplicate orders.
Duplicate inbound confirmation must not create duplicate Paystack attempts unless the previous attempt is terminal/expired and policy allows restart.
Duplicate send-payment-link worker must not send duplicate links inside the configured dedupe window.
Duplicate send-ticket-link worker must not rotate delivery token unless explicitly requested and allowed.
```

Redis structures:

```text
whatsapp:dedupe:message:{provider_message_id}              # SET NX EX 24h
whatsapp:dedupe:send_payment_link:{conversation_id}:{order_id} # SET NX EX 5m-30m
whatsapp:dedupe:send_ticket_link:{conversation_id}:{ticket_issue_id} # SET NX EX 5m-30m
whatsapp:session:{phone_e164_or_wa_id}                     # hash, TTL per VS-17/VS-18
```

---

## 11. DeliveryAttempt Rules

If DeliveryAttempt exists and is accepted as first-class audit state, VS-19 must create/queue attempts for:

```text
payment link message
payment-pending reassurance message if configured as auditable
secure ticket link message
manual-review/handoff message if configured as auditable
```

Minimum fields:

```text
sales_order_id
ticket_issue_id optional for payment-link messages
channel = whatsapp
provider = meta
recipient masked/protected
status = queued | sent | failed | fallback_required
template_name optional
within_whatsapp_window boolean if known
provider_message_id after send success
attempt_number
correlation_id
sent_at / delivered_at
```

Rules:

```text
Failed WhatsApp sends must not disappear.
If 24-hour window/template fallback is not implemented yet, mark fallback_required/manual_review as appropriate and leave full policy to VS-20.
Do not treat DeliveryAttempt delivered as proof of payment or proof of ticket validity.
```

---

## 12. RED/GREEN Test Plan

### RED tests first

```text
RED: confirming order through WhatsApp calls approved Sales checkout facade, not Redis directly.
RED: payment link is initialized through approved Paystack initializer, not raw Req in conversation code.
RED: payment link send uses VS-16 WhatsApp client boundary.
RED: duplicate confirmation message does not create duplicate orders.
RED: duplicate payment-link worker does not send duplicate links within dedupe window.
RED: awaiting_payment status request re-sends safe payment instructions without new order.
RED: payment_pending status request reassures user and does not say ticket not found.
RED: paid_verified/fulfillment_queued status says ticket is being prepared.
RED: ticket_issued status sends secure ticket page link.
RED: revoked/refunded/cancelled TicketIssue does not send active ticket link.
RED: manual_review state returns support/handoff message.
RED: expired checkout with late verified payment follows VS-07C/VS-14 policy and does not blindly issue.
RED: no WhatsApp code calls Tickets.Issuer directly.
RED: no WhatsApp code marks paid_verified or ticket_issued.
RED: no WhatsApp code mutates Attendee or scanner state.
RED: no authorization_url/access_code/customer phone/raw payload is logged.
```

### GREEN targets

```text
GREEN: WhatsApp can safely hand off customer to Paystack.
GREEN: WhatsApp can accurately report payment/ticket status from durable Sales state.
GREEN: WhatsApp can send secure ticket link only after issue.
GREEN: Duplicate messages/workers are safe.
GREEN: Every state change is audited.
GREEN: VS-20 can add delivery-window fallback without rewriting VS-19.
```

---

## 13. Security and PII Rules

```text
Do not log phone_e164, buyer_email, buyer_name, raw inbound message body, Paystack authorization_url, Paystack access_code, ticket URL token, delivery token hash, QR token hash, or raw provider payloads.
Do not store Paystack authorization_url in WhatsApp Redis session state.
Do not store full raw WhatsApp payload in Conversation.state_data unless retention/encryption policy allows it.
Use masked phone/email in admin-visible summaries.
Use correlation_id, conversation_id, order_id, payment_attempt_id, and provider_reference hashes/last4 only for logs.
```

Customer safety:

```text
Never tell customer "payment not received" if a verified payment or pending verification exists.
Never send active ticket link for revoked/refunded/cancelled tickets.
Never ask for card details in WhatsApp.
Always direct payment to Paystack-hosted link.
```

---

## 14. Performance and Scaling Review

### Hot data

```text
WhatsApp session state: Redis hash, TTL from VS-17/VS-18.
Deduplication: Redis SET NX EX keys.
Active selected menu state: Redis hot state mirrored to durable Conversation checkpoints.
```

### Warm data

```text
Active offers: Cachex/Redis warm cache from VS-03/VS-05.
Conversation checkpoint summaries: Postgres durable state with bounded reads.
```

### Cold durable truth

```text
Sales Order, CheckoutSession, PaymentAttempt, TicketIssue, DeliveryAttempt, Conversation, StateTransition in Postgres/Ash.
```

### Redis keys and TTLs

```text
whatsapp:dedupe:message:{provider_message_id}: 24h
whatsapp:dedupe:send_payment_link:{conversation_id}:{order_id}: 5m-30m
whatsapp:dedupe:send_ticket_link:{conversation_id}:{ticket_issue_id}: 5m-30m
whatsapp:session:{wa_id}: 24h active session, extend on inbound
```

### DB/index requirements

```text
sales_conversations(phone_e164)
sales_conversations(wa_id)
sales_conversations(state, expires_at)
sales_orders(whatsapp_conversation_id)
sales_orders(public_reference)
sales_orders(event_id, status, inserted_at)
sales_checkout_sessions(sales_order_id)
sales_payment_attempts(sales_order_id, status)
sales_ticket_issues(sales_order_id, status)
sales_delivery_attempts(sales_order_id, channel, status, inserted_at)
sales_state_transitions(entity_type, entity_id, inserted_at)
```

### Scaling rules

```text
Do not load all offers/orders/tickets for a phone number.
Always paginate or fetch current active conversation/order only.
Do not call Postgres repeatedly for every menu render if Redis session has valid checkpoint and no durable transition is needed.
Do not call Paystack initialize on repeated status checks.
Use Oban workers for outbound sends.
Use PubSub only for admin/dashboard visibility if an existing convention exists.
```

---

## 15. Observability

Telemetry names:

```text
[:fastcheck, :messaging, :whatsapp, :payment_flow, :started]
[:fastcheck, :messaging, :whatsapp, :payment_flow, :checkout_confirmed]
[:fastcheck, :messaging, :whatsapp, :payment_flow, :payment_link_queued]
[:fastcheck, :messaging, :whatsapp, :payment_flow, :payment_pending_response]
[:fastcheck, :messaging, :whatsapp, :payment_flow, :ticket_link_queued]
[:fastcheck, :messaging, :whatsapp, :payment_flow, :manual_review]
[:fastcheck, :messaging, :whatsapp, :payment_flow, :failed]
```

Log metadata allowed:

```text
conversation_id
order_id
payment_attempt_id
ticket_issue_id
state
transition
correlation_id
idempotency_key hash/last4 only
provider_message_id hash/last4 only
```

---

## 16. TOON Coding-Agent Prompt

| Field | Content |
|---|---|
| Task | Implement VS-19 WhatsApp Payment and Ticket Flow in `JCSchoeman96/FastCheckin`. |
| Objective | Connect the VS-18 WhatsApp number-only conversation flow to the approved Sales checkout, Paystack transaction initialization, and secure ticket-link retrieval paths while keeping WhatsApp as an interface layer only. |
| Output | `lib/fastcheck/messaging/whatsapp/payment_flow.ex`, payment/ticket renderers, bounded Oban workers for payment-link and ticket-link sends, minimal router/controller worker handoff updates if needed, and tests for duplicate messages, payment-pending status, secure ticket link delivery, DeliveryAttempt audit, and forbidden boundary calls. |
| Note | Use approved Sales checkout facades and Paystack initializer; do not call Redis inventory or Paystack raw `Req` directly from conversation code. Use VS-16 outbound WhatsApp client. Use VS-11 secure ticket page for ticket links. Use Redis `SET NX EX` for message/send dedupe: message 24h, send-payment-link 5m-30m, send-ticket-link 5m-30m. Store hot session in Redis hash with 24h TTL and durable `Sales.Conversation` checkpoints. Required indexes: `sales_conversations(phone_e164)`, `sales_conversations(wa_id)`, `sales_orders(whatsapp_conversation_id)`, `sales_payment_attempts(sales_order_id,status)`, `sales_ticket_issues(sales_order_id,status)`, `sales_delivery_attempts(sales_order_id,channel,status,inserted_at)`. Invalidation: none for scanner; no event_sync_version bump here. PubSub: only dashboard/admin status broadcasts if existing convention exists. Forbidden: ticket issuance, payment verification, Attendee mutation, scanner/mobile API changes, Paystack refund, direct Redis inventory mutation, raw provider payload logging, authorization_url/access_code logging. |
| Success | A WhatsApp customer can safely receive a Paystack payment link, receive accurate payment/ticket status responses, and receive a secure ticket page link only after backend ticket issuance, with duplicate messages/workers safe and all authority remaining in Sales/Payment/Ticket services. |

---

## 17. Copy-Paste Prompt for Coding Agent

```text
You are implementing FastCheck Sales VS-19 — WhatsApp Payment and Ticket Flow in JCSchoeman96/FastCheckin.

Goal:
Connect the WhatsApp number-only conversation flow to the approved Sales checkout/payment/ticket-link services.

Use these boundaries:
- WhatsApp is only the customer interface.
- Sales checkout owns order/session/inventory reservation.
- Paystack initializer owns provider transaction initialization.
- Paystack verification owns payment truth.
- Tickets.Issuer owns ticket issuance.
- Secure ticket page owns ticket display.
- VS-20 owns 24-hour template/fallback delivery policy.

Implement:
1. `FastCheck.Messaging.WhatsApp.PaymentFlow`.
2. Payment-status and ticket-link renderers.
3. Worker or service handoff for sending Paystack links through the VS-16 client.
4. Worker or service handoff for sending secure ticket page links after ticket issue.
5. Redis dedupe for duplicate inbound confirmations and outbound sends.
6. Durable Conversation state transitions and StateTransition audit.
7. DeliveryAttempt audit rows if DeliveryAttempt is available.
8. Tests for duplicate inbound messages, duplicate workers, payment-pending reassurance, ticket-issued link send, revoked/refunded/cancelled denial, and no boundary violations.

Do not:
- issue tickets from WhatsApp code
- verify payments from WhatsApp code
- mark paid_verified or ticket_issued from WhatsApp code
- mutate Attendee/scanner/mobile sync
- call Redis inventory directly
- call raw Req for Paystack or Meta inside PaymentFlow
- log authorization_url, access_code, phone, email, raw message body, raw payloads, tokens, or token hashes
```

---

## 18. Human Review Checklist

```text
[ ] WhatsApp payment flow uses approved Sales checkout facade.
[ ] WhatsApp payment flow uses approved Paystack initializer.
[ ] WhatsApp outbound sends use VS-16 client.
[ ] Duplicate inbound confirmation does not create duplicate order/payment attempt.
[ ] Duplicate payment-link worker does not send repeated links within dedupe window.
[ ] Status request while payment_pending gives reassurance, not "ticket not found".
[ ] Ticket link is only sent for issued, non-revoked TicketIssue.
[ ] Secure ticket page link is used; raw QR/tokens are not sent directly.
[ ] DeliveryAttempt audit exists or explicit reason is documented if deferred.
[ ] No Paystack verification logic was added here.
[ ] No ticket issuance logic was added here.
[ ] No Attendee/scanner/mobile sync mutation was added here.
[ ] No Redis inventory mutation was added here.
[ ] Logs are redacted.
[ ] StateTransition audit is present for durable state changes.
```

---

## 19. Next Slice

```text
VS-20 — WhatsApp Delivery Window Handling
```
