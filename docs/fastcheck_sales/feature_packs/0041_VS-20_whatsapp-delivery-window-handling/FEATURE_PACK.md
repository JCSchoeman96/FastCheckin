# FastCheck Sales Feature Planning Pack — VS-20 WhatsApp Delivery Window Handling

**Pack ID:** `0041_VS-20_whatsapp-delivery-window-handling`  
**Slice:** `VS-20`  
**Slice name:** WhatsApp Delivery Window Handling  
**Version:** `v1.0`  
**Date:** 2026-06-13  
**Status:** Implementation-ready planning pack  
**Primary area:** WhatsApp / Delivery / Meta Templates / Fallback / Audit  
**Repo truth:** `JCSchoeman96/FastCheckin`  
**Repository path:** `docs/fastcheck_sales/feature_packs/0041_VS-20_whatsapp-delivery-window-handling/`  
**Source docs:** `docs/fastcheck_sales/SOURCE_DOCS/FastCheck_Sales_Ash_Atlas_Planning_Pack_v0.2.3_HARDENED.md`, `docs/fastcheck_sales/SOURCE_DOCS/FastCheck_Sales_Vertical_Slice_Roadmap_v1.1.3_HARDENED.md`  
**Depends on:** VS-16, VS-11, VS-19, VS-00B, VS-01D, VS-07C, VS-09D, VS-15A, VS-21A  
**Blocks:** VS-22, VS-23C, WhatsApp-first production launch  

---

## 1. Purpose

Implement reliable WhatsApp ticket delivery behavior around Meta’s 24-hour customer service window.

VS-20 owns delivery-policy orchestration only:

```text
Ticket issued / secure ticket link available
  -> choose allowed WhatsApp delivery mode
  -> create DeliveryAttempt audit record
  -> send session message if inside service window
  -> send approved utility template if outside service window
  -> fall back to email or manual_review when delivery cannot proceed
  -> record provider result without hiding failure
```

This slice must not become a second ticket-issuance or payment-verification path.

Core principle:

```text
DeliveryAttempt is the durable audit source for delivery attempts.
WhatsApp is a delivery channel, not payment authority, ticket authority, or scanner authority.
```

---

## 2. FastCheckin Current-State Findings

Use current FastCheckin structure and conventions:

```text
Existing Phoenix app: FastCheck / :fastcheck
Existing outbound provider-client pattern: plain Req-style modules, not Ash actions
Existing mailer boundary: FastCheck.Mailer using Swoosh
Existing runtime config pattern: read secrets/env in config/runtime.exs
Existing router separation: browser/dashboard/API/mobile scopes are explicit
Existing request tracing: FastCheckWeb.Plugs.LoggerMetadata
```

No existing `DeliveryAttempt` implementation was found in FastCheckin during planning, so this slice must rely on the Sales resource/model planned in VS-01D and used by VS-19. If the resource already exists by implementation time, extend it minimally; otherwise create only the required action behavior from the approved Sales resource skeleton.

---

## 3. Ultimate Outcome

After VS-20:

```text
WhatsApp ticket delivery does not silently fail.
Every send attempt is recorded in DeliveryAttempt.
Meta 24-hour window behavior is deterministic.
Session messages are used only inside the active service window.
Approved utility templates are used outside the service window.
Email/manual-review fallback is recorded when WhatsApp cannot deliver.
Operators can see delivery status in admin views without raw payload leaks.
Duplicate workers do not send duplicate messages.
```

---

## 4. Scope

### In scope

```text
Delivery policy module for choosing session/template/fallback.
DeliveryAttempt creation and transitions.
WhatsApp 24-hour window calculation from Conversation.last_message_at.
Template send path using VS-16 outbound client.
Session message send path using VS-16 outbound client.
Email fallback enqueue boundary using FastCheck.Mailer only if fallback is enabled.
Manual-review fallback when no allowed delivery channel exists.
Idempotency for delivery workers and resend requests.
Tests for inside-window, outside-window, template failure, fallback, duplicate worker safety, and log redaction.
```

### Out of scope

```text
No Paystack verification.
No Paystack refund API.
No order payment-state mutation except delivery-related StateTransition/DeliveryAttempt.
No TicketIssue creation.
No Attendee creation or scanner mutation.
No revocation implementation.
No conversation menu implementation.
No inbound webhook implementation.
No Meta template approval workflow UI.
No bulk marketing messaging.
```

---

## 5. Recommended Files

```text
lib/fastcheck/messaging/whatsapp/delivery_policy.ex
lib/fastcheck/messaging/whatsapp/delivery_window.ex
lib/fastcheck/messaging/whatsapp/ticket_message_builder.ex
lib/fastcheck/messaging/whatsapp/template_catalog.ex
lib/fastcheck/workers/send_whatsapp_ticket_worker.ex
lib/fastcheck/workers/send_ticket_email_fallback_worker.ex      # optional, if email fallback is enabled
lib/fastcheck/sales/delivery_attempt.ex
lib/fastcheck/sales/state_transition.ex
lib/fastcheck/sales/conversation.ex
lib/fastcheck/sales/ticket_issue.ex
lib/fastcheck/sales/order.ex

test/fastcheck/messaging/whatsapp/delivery_policy_test.exs
test/fastcheck/messaging/whatsapp/delivery_window_test.exs
test/fastcheck/workers/send_whatsapp_ticket_worker_test.exs
test/fastcheck/sales/delivery_attempt_test.exs
test/fastcheck/log_redaction/whatsapp_delivery_log_redaction_test.exs
```

Keep provider HTTP inside `FastCheck.Messaging.WhatsApp.Client` from VS-16. Do not duplicate HTTP code in workers.

---

## 6. Domain Model

### Domain

```text
FastCheck.Messaging.WhatsApp
FastCheck.Sales.DeliveryAttempt
FastCheck.Sales.Conversation
FastCheck.Sales.TicketIssue
```

### Core entities

```text
Conversation
  phone_e164
  wa_id
  last_message_at
  state
  state_data

TicketIssue
  status
  delivery_token_hash
  delivery_token_expires_at
  revoked_at

DeliveryAttempt
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
```

### Policies

```text
system creates and updates DeliveryAttempt.
admin/operator reads masked delivery state.
customer_session cannot read raw DeliveryAttempt provider internals.
raw provider payloads are not shown in normal dashboard flows.
```

### State machine

DeliveryAttempt minimum states:

```text
queued
sent
delivered
failed
fallback_required
cancelled
manual_review
```

Allowed transitions:

```text
queued -> sent | failed | fallback_required | cancelled
sent -> delivered | failed | fallback_required
failed -> fallback_required | manual_review | cancelled
fallback_required -> queued | failed | manual_review
manual_review -> queued only through explicit audited retry/resend action
cancelled -> terminal unless explicit resend creates a new DeliveryAttempt
```

---

## 7. WhatsApp 24-Hour Window Rules

### Window source

Use:

```text
FastCheck.Sales.Conversation.last_message_at
```

Rules:

```text
If last inbound customer message is within 24 hours, session message is allowed.
If outside 24 hours, use approved utility template.
If no Conversation exists or last_message_at is unknown, default to template path or manual_review.
Do not send free-form ticket links outside the 24-hour customer service window.
Do not assume server local timezone; use UTC DateTime.
```

### Delivery decision matrix

| Case | Required outcome |
|---|---|
| Inside 24h window | Create DeliveryAttempt, send WhatsApp session message. |
| Outside 24h and approved ticket template configured | Create DeliveryAttempt, send approved utility template. |
| Outside 24h and template missing/unapproved | Mark fallback_required or manual_review. |
| WhatsApp provider 429 | Retry with backoff; keep DeliveryAttempt failed/retryable. |
| WhatsApp provider 401/403 | Manual review/config error; do not retry forever. |
| WhatsApp provider 5xx/timeout | Retry idempotently. |
| TicketIssue revoked/not active | Do not send; mark cancelled/manual_review according to policy. |
| Delivery token expired | Generate/rotate only through approved VS-08/VS-11 token service; do not create plaintext token in logs. |

---

## 8. DeliveryAttempt Audit Contract

Every outbound ticket delivery attempt must create or reuse a DeliveryAttempt row before provider send.

Required fields:

```text
sales_order_id
ticket_issue_id
channel = whatsapp | email
provider = meta | swoosh | manual
recipient = masked/protected phone/email storage per policy
status
template_name
within_whatsapp_window
attempt_number
correlation_id
```

After provider response:

```text
provider_message_id for successful Meta sends
provider_error_code for failed provider result
provider_error_message sanitized/truncated
sent_at on accepted send
delivered_at only when webhook/status confirms delivery, if implemented later
```

Rules:

```text
Do not use TicketIssue.delivered_at as the only delivery truth.
Do not overwrite a failed attempt with a later successful attempt; create a new attempt or transition according to policy.
Do not store raw provider payloads in DeliveryAttempt unless the approved security policy explicitly allows restricted raw storage.
```

---

## 9. Fallback Policy

Fallback channels:

```text
email
manual_review
```

Email fallback is allowed only when:

```text
buyer_email exists and passes basic validation.
email ticket message uses secure ticket link only.
email send is idempotent.
logs do not include full ticket link/token.
```

Manual review is required when:

```text
no valid WhatsApp route exists.
no approved template exists outside 24h window.
email fallback is unavailable.
Meta auth/config failure occurs.
recipient phone is invalid.
Delivery token generation fails.
```

---

## 10. Idempotency and Worker Rules

Worker:

```text
FastCheck.Workers.SendWhatsAppTicketWorker
```

Queue:

```text
delivery
```

Uniqueness:

```text
by delivery_attempt_id or ticket_issue_id + delivery_purpose + recipient + idempotency_key
```

Rules:

```text
Worker must load fresh TicketIssue, Order, Conversation, and DeliveryAttempt state.
Worker must not send if TicketIssue is revoked/cancelled/not issued.
Worker must not send if DeliveryAttempt is already sent/delivered.
Worker must not create duplicate Meta sends on retry.
Worker may retry transient Meta failures.
Worker must not retry permanent config/auth failures forever.
```

---

## 11. RED/GREEN Test Plan

### RED tests first

```text
RED: inside 24h window chooses session message.
RED: outside 24h window chooses approved utility template.
RED: outside 24h with missing template moves to fallback_required/manual_review.
RED: successful Meta send records DeliveryAttempt.sent and provider_message_id.
RED: Meta 429 schedules retry without duplicate DeliveryAttempt.
RED: Meta 401/403 moves to manual_review/config error.
RED: timeout/5xx retries idempotently.
RED: duplicate worker execution does not send duplicate WhatsApp messages.
RED: revoked TicketIssue is not sent.
RED: expired/invalid delivery token is not sent without approved token refresh path.
RED: email fallback is queued only when buyer_email is valid and policy allows it.
RED: manual_review is set when no delivery channel is available.
RED: logs do not include phone, email, ticket URL, delivery token, token hash, access token, or raw provider payload.
RED: no Paystack, ticket issuance, Attendee, scanner, mobile sync, or Redis inventory behavior is called.
```

### GREEN targets

```text
GREEN: WhatsApp delivery follows deterministic session/template/fallback policy.
GREEN: Every attempt is audited in DeliveryAttempt.
GREEN: Duplicate delivery jobs are safe.
GREEN: Delivery failures are visible to admin/manual review.
GREEN: WhatsApp-first launch has reliable delivery-window handling.
```

---

## 12. Performance and Scaling Review

### Data placement

```text
Hot: Redis session state from VS-17, short-lived dedupe keys.
Warm: template catalog/config cache, 30m–24h depending on template volatility.
Cold: DeliveryAttempt, TicketIssue, Conversation, StateTransition in Postgres/Ash.
```

### Redis

Required keys:

```text
whatsapp:delivery:dedupe:{idempotency_key}        # SET NX EX, TTL 24h minimum
whatsapp:delivery:rate:{phone_e164_hash}          # counter/zset, short TTL
whatsapp:session:{wa_id}                          # existing VS-17 session hash
```

Rules:

```text
Use Redis dedupe to avoid duplicate sends during retries.
Do not store plaintext phone numbers in Redis keys; hash recipient identifiers.
Do not store ticket URLs or plaintext tokens in Redis.
No Sales inventory Redis mutation in this slice.
```

### Postgres indexes

Required indexes:

```text
sales_delivery_attempts(ticket_issue_id, status)
sales_delivery_attempts(sales_order_id, status)
sales_delivery_attempts(provider_message_id)
sales_delivery_attempts(channel, status, inserted_at)
sales_delivery_attempts(correlation_id)
sales_ticket_issues(status, delivery_token_expires_at)
sales_conversations(phone_e164)
sales_conversations(wa_id)
sales_conversations(last_message_at)
```

### Latency

```text
Do not perform delivery sends in LiveView/controller request cycle.
Use Oban workers.
Provider call timeout should be bounded.
Use retry/backoff for transient provider errors.
```

---

## 13. Security and PII

Forbidden logs:

```text
Meta access token
raw phone number
buyer email
full ticket URL
delivery token
qr token
raw provider payload
message body containing a ticket link
```

Allowed logs:

```text
ticket_issue_id
sales_order_id
delivery_attempt_id
provider_message_id
status
reason_code
correlation_id
recipient_hash
```

Rules:

```text
Store recipient only according to VS-00B policy.
Mask recipient in admin lists.
Never expose raw Meta errors directly to customers.
Only show operator-safe failure summary.
```

---

## 14. Observability

Telemetry names:

```text
[:fastcheck, :sales, :delivery, :selected]
[:fastcheck, :sales, :delivery, :queued]
[:fastcheck, :sales, :delivery, :sent]
[:fastcheck, :sales, :delivery, :failed]
[:fastcheck, :sales, :delivery, :fallback_required]
[:fastcheck, :sales, :delivery, :manual_review]
[:fastcheck, :messaging, :whatsapp, :template_send]
[:fastcheck, :messaging, :whatsapp, :session_send]
```

Metrics:

```text
send success count
send failure count by reason
fallback_required count
manual_review delivery count
Meta 429 count
Meta auth/config failure count
delivery p95/p99 latency
```

---

## 15. TOON Coding-Agent Prompt

| Field | Content |
|---|---|
| Task | Implement VS-20 WhatsApp Delivery Window Handling in `JCSchoeman96/FastCheckin`. |
| Objective | Make WhatsApp ticket delivery reliable by selecting session message, utility template, email fallback, or manual review according to Meta 24-hour window rules, while recording every attempt in DeliveryAttempt. |
| Output | `lib/fastcheck/messaging/whatsapp/delivery_policy.ex`; `delivery_window.ex`; `ticket_message_builder.ex`; updates to `template_catalog.ex`; `lib/fastcheck/workers/send_whatsapp_ticket_worker.ex`; optional email fallback worker; DeliveryAttempt actions/transitions; RED/GREEN tests for delivery window, provider errors, fallback, idempotency, and log redaction. |
| Note | Use VS-16 `FastCheck.Messaging.WhatsApp.Client` for all Meta HTTP. Use VS-17 Conversation/session data to determine 24-hour window from `Conversation.last_message_at`. Use VS-11 secure ticket link only; never log full URL/token. DeliveryAttempt is the audit source. Required indexes: `sales_delivery_attempts(ticket_issue_id,status)`, `sales_delivery_attempts(sales_order_id,status)`, `sales_delivery_attempts(provider_message_id)`, `sales_delivery_attempts(channel,status,inserted_at)`, `sales_conversations(wa_id)`, `sales_conversations(last_message_at)`. Cache/TTL: template catalog Cachex 30m–24h; Redis dedupe `whatsapp:delivery:dedupe:{idempotency_key}` TTL 24h minimum; recipient rate-limit zsets/counters short TTL; no Sales inventory Redis mutation. PubSub: broadcast delivery status only if VS-12/VS-21B admin convention exists. Oban: use `delivery` queue; idempotent by delivery_attempt_id or ticket_issue_id + recipient + purpose. Forbidden: Paystack verification/refund, ticket issuance, Attendee/scanner/mobile mutation, inbound webhook changes, conversation menu changes, bulk marketing. |
| Success | Tickets are delivered through the correct WhatsApp channel for the window state, failures are audited and recoverable, duplicate jobs do not duplicate sends, and WhatsApp-first launch can rely on support-visible delivery status. |

---

## 16. Copy-Paste Prompt for Coding Agent

```text
You are implementing FastCheck Sales VS-20 — WhatsApp Delivery Window Handling in JCSchoeman96/FastCheckin.

Goal:
Implement reliable WhatsApp ticket delivery selection and audit behavior around Meta's 24-hour customer service window.

Use current FastCheckin truth:
- Use the VS-16 WhatsApp outbound client for Meta HTTP.
- Use the VS-17 Conversation/session data to determine last inbound customer message time.
- Use FastCheck.Mailer/Swoosh only through an explicit email fallback boundary if fallback is enabled.
- Use DeliveryAttempt as the durable audit record.
- Use secure ticket links from VS-11 only.

Implement:
1. Delivery window calculation from Conversation.last_message_at using UTC DateTime.
2. Delivery policy: inside 24h -> session message; outside 24h -> approved utility template; unavailable -> fallback/manual_review.
3. SendWhatsAppTicketWorker with idempotent provider sends.
4. DeliveryAttempt transitions queued/sent/failed/fallback_required/manual_review.
5. Provider response classification for 2xx, 400, 401/403, 429, 5xx, timeout, transport error.
6. Redis dedupe keys with TTL 24h minimum; no plaintext phones/tokens in keys.
7. Tests for window decisions, provider failures, duplicate worker execution, fallback, and log redaction.

Do not:
- verify Paystack payments
- issue tickets
- mutate Attendees/scanner/mobile sync
- mutate Redis inventory
- add inbound webhook logic
- implement conversation menus
- send bulk marketing messages
- log phone/email/ticket URL/tokens/raw provider payloads
```

---

## 17. Human Review Checklist

```text
[ ] Delivery policy uses Conversation.last_message_at and UTC time.
[ ] Inside-window messages use session message path.
[ ] Outside-window messages use approved utility template path.
[ ] Missing template produces fallback/manual_review, not silent drop.
[ ] Every send attempt creates/updates DeliveryAttempt.
[ ] Duplicate workers do not duplicate Meta sends.
[ ] Provider 429/5xx/timeout behavior is retryable and bounded.
[ ] Provider 401/403 behavior moves to manual_review/config error.
[ ] Revoked/non-issued TicketIssue is not delivered.
[ ] Secure ticket link/token is never logged.
[ ] Recipient PII is masked/protected.
[ ] No Paystack behavior added.
[ ] No ticket issuance behavior added.
[ ] No Attendee/scanner/mobile mutation added.
[ ] No Sales inventory Redis mutation added.
[ ] Tests cover success and failure paths.
```

---

## 18. Next Slice

```text
VS-21A — Observability Naming and Log Redaction Foundation
```
