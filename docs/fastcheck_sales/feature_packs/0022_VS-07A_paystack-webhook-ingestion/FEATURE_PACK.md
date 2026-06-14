# FastCheck Sales Feature Planning Pack — VS-07A Paystack Webhook Ingestion

**Pack ID:** `0022_VS-07A_paystack-webhook-ingestion`  
**Slice:** `VS-07A`  
**Slice name:** Paystack Webhook Ingestion  
**Version:** `v1.0`  
**Date:** 2026-06-13  
**Repository path:** `docs/fastcheck_sales/feature_packs/0022_VS-07A_paystack-webhook-ingestion/`  
**Status:** Implementation planning pack — implementation allowed inside this slice only  
**Primary area:** Payments / Webhook / Security / Oban / Idempotency  
**Depends on:** VS-06B, VS-06C, VS-06A, VS-00B, VS-00A, VS-01C, VS-01F, VS-01G, VS-21A  
**Blocks:** VS-07B, VS-07C, VS-19, VS-21B, VS-22  
**Source docs:**

```text
docs/fastcheck_sales/SOURCE_DOCS/FastCheck_Sales_Ash_Atlas_Planning_Pack_v0.2.3_HARDENED.md
docs/fastcheck_sales/SOURCE_DOCS/FastCheck_Sales_Vertical_Slice_Roadmap_v1.1.3_HARDENED.md
```

---

## 1. Purpose

This pack instructs a coding agent to implement **Paystack webhook ingestion only**.

The goal is to receive Paystack webhook requests, verify the provider signature, persist a durable `PaymentEvent`, dedupe duplicate events, enqueue a worker, and return quickly to Paystack.

Critical principle:

```text
Webhook ingestion is not payment verification.
Webhook ingestion is not payment settlement.
Webhook ingestion must never issue tickets or mutate scanner-visible state.
```

This slice creates the safe entrypoint and durable event record needed by VS-07B. VS-07B performs server-side transaction verification. VS-07C applies mismatch, late-payment, duplicate, and manual-review state outcomes.

---

## 2. Ultimate Outcome

After VS-07A is complete:

```text
FastCheck has a Paystack webhook endpoint that preserves the raw request body for signature verification.
Valid signed Paystack webhook payloads are stored as PaymentEvent records.
Duplicate webhook deliveries are deduped using database uniqueness and a Redis SETNX-style key.
A PaystackWebhookWorker is enqueued for valid, non-duplicate events.
The HTTP endpoint responds quickly and does not perform heavy business logic in the controller.
Invalid signatures do not enqueue verification and do not mutate order/payment/ticket state.
Logs and telemetry are redacted and correlation-safe.
```

The system is then ready for VS-07B to consume stored `PaymentEvent` rows and verify transactions server-side.

---

## 3. Scope

### In scope

```text
Add or finalize Paystack webhook route.
Add or finalize Paystack webhook controller endpoint.
Preserve raw body bytes for signature verification.
Use the VS-06A Paystack WebhookVerifier boundary.
Parse only after signature handling is safe.
Extract provider_event_id, provider_reference, event_type, and payload_hash.
Persist FastCheck.Sales.PaymentEvent with processing_status and signature_valid.
Use unique DB indexes and Redis SETNX-style dedupe to handle repeated provider delivery.
Enqueue FastCheck.Workers.PaystackWebhookWorker for valid new events only.
Return quickly from the HTTP endpoint.
Add telemetry and redacted structured logs.
Add tests for success, invalid signature, malformed JSON, duplicate delivery, worker enqueue, no heavy processing, and boundary creep.
Patch PaymentEvent Ash action/policy gaps only where required for ingestion.
```

### Out of scope

```text
No server-side transaction verification.
No call to Paystack Verify Transaction API.
No mark_paid_unverified.
No mark_paid_verified.
No amount/currency/reference/provider-status matching.
No payment-after-expiry decision.
No order fulfillment transition.
No inventory consume, release, reserve, or re-reserve.
No ticket issuance.
No Attendee creation or mutation.
No scanner/mobile sync changes.
No DeliveryAttempt creation.
No WhatsApp/Meta behavior.
No admin manual-review UI.
No refund handling.
No customer-facing payment status messaging.
```

---

## 4. Required Pre-Implementation Discovery

Before changing code, the agent must inspect the repository and document findings in the final report:

```text
Existing Phoenix endpoint/router structure.
Existing raw body access strategy, if any.
Existing JSON parser/body_reader configuration.
Existing webhook controller namespace conventions.
Existing Ash action names for PaymentEvent.
Existing PaymentEvent table fields, indexes, and identities from VS-01C/VS-01G.
Existing Paystack WebhookVerifier module and signature API from VS-06A.
Existing Paystack config module and secret access pattern.
Existing Oban worker naming, queue, and uniqueness conventions.
Existing Redis adapter/helper pattern for SETNX dedupe.
Existing telemetry/log redaction helper conventions from VS-21A.
Existing test fixtures, ConnCase, Oban testing mode, and Redis test helpers.
```

Do not invent new conventions when the project already has a clear pattern.

---

## 5. Provider Behavior Notes

Use official Paystack behavior as provider input, but keep FastCheck business authority internal.

Paystack webhook signature expectations:

```text
Header: X-Paystack-Signature
Algorithm: HMAC SHA512 over the event payload using the Paystack secret key
Comparison: constant-time comparison
Body requirement: verify against the exact raw request body where possible
```

Provider events must be treated as notifications only.

```text
A charge.success event can start local verification work.
It must not deliver value by itself.
FastCheck must verify the transaction server-side in VS-07B before marking payment verified or issuing tickets.
```

Optional IP allowlisting can be supported as a defense-in-depth setting, but it must not replace signature verification.

---

## 6. Domain and Boundary Details

### Ash domain

```text
FastCheck.Sales
```

### Ash resources touched

```text
FastCheck.Sales.PaymentEvent
FastCheck.Sales.StateTransition only if an existing audit convention requires recording rejected/received events
```

### Ash resources read only if needed

```text
FastCheck.Sales.PaymentAttempt
```

Only use `PaymentAttempt` for safe linkage or dedupe metadata if already supported. Do not update it in this slice.

### Ash resources explicitly forbidden from mutation

```text
FastCheck.Sales.Order
FastCheck.Sales.OrderLine
FastCheck.Sales.CheckoutSession
FastCheck.Sales.PaymentAttempt
FastCheck.Sales.TicketIssue
FastCheck.Sales.DeliveryAttempt
FastCheck.Sales.Conversation
```

### Plain modules expected

Use actual repository names if they differ. Preferred names:

```text
lib/fastcheck/payments/paystack/webhook_verifier.ex
lib/fastcheck/payments/paystack/webhook_event_parser.ex
lib/fastcheck/payments/paystack/payload_sanitizer.ex
lib/fastcheck/payments/paystack/event_dedupe.ex
lib/fastcheck/workers/paystack_webhook_worker.ex
lib/fastcheck_web/controllers/webhooks/paystack_controller.ex
```

### Preferred route

Use existing route style if present. If no convention exists, prefer:

```text
POST /webhooks/paystack
```

The route must be excluded from browser CSRF expectations and must run through API/webhook-safe plugs only.

### Preferred test files

Use project conventions. If no convention exists, prefer:

```text
test/fastcheck_web/controllers/webhooks/paystack_controller_test.exs
test/fastcheck/payments/paystack/webhook_verifier_test.exs
test/fastcheck/payments/paystack/webhook_ingestion_test.exs
test/fastcheck/payments/paystack/webhook_dedupe_test.exs
test/fastcheck/workers/paystack_webhook_worker_enqueue_test.exs
test/fastcheck/payments/paystack/webhook_security_test.exs
test/fastcheck/payments/paystack/webhook_boundary_test.exs
```

---

## 7. PaymentEvent Ingestion Contract

### Required persisted fields

`PaymentEvent` should store or derive the following, using the actual resource fields from VS-01C:

```text
provider = "paystack"
provider_event_id
provider_reference
event_type
signature_valid
payload_hash
raw_payload
received_at
processing_status
processing_attempt_count
last_processing_error
last_processing_error_at
correlation_id or request_id if the project already supports it
```

### Required processing statuses for this slice

Use existing enum values if already defined. If not, prefer:

```text
stored
queued
duplicate
rejected_invalid_signature
rejected_malformed
```

Do not add verification statuses here. Verification states belong to VS-07B and VS-07C.

### Raw payload policy

```text
Valid signed payloads may be stored as restricted raw_payload according to VS-00B.
Raw payload must never be logged.
Raw payload must be admin/system-restricted.
Operator views must show summarized data only.
Invalid signature payloads should not be trusted. Prefer storing payload_hash and minimal metadata only, or store raw payload only if the accepted security policy explicitly allows it.
```

### Payload hash

```text
payload_hash = SHA256(raw_body_bytes)
```

Use the same byte sequence used for signature verification.

### Provider event ID extraction

Extract from Paystack payload where available. Use project-safe parser rules.

Preferred mapping:

```text
provider_event_id = payload["id"] or payload["event_id"] or provider-specific stable event identifier if Paystack provides one
provider_reference = payload["data"]["reference"]
event_type = payload["event"]
```

If no stable provider event ID exists:

```text
provider_event_id = nil
unique fallback = provider + payload_hash
```

This matches the index strategy from the atlas.

---

## 8. Dedupe Contract

Use two layers of dedupe:

### Layer 1 — Redis hot dedupe

```text
Key: sales:payments:paystack:webhook:{dedupe_key}
Structure: string/counter via SETNX-style insert
TTL: 24h minimum
Value: received timestamp or payment_event_id after persistence if available
```

`dedupe_key` should be:

```text
provider_event_id when present
payload_hash fallback when provider_event_id is absent
```

### Layer 2 — Postgres durable dedupe

Required indexes from VS-01G:

```text
unique(provider, provider_event_id)
unique(provider, payload_hash) where provider_event_id is null
index(provider_reference)
index(processing_status, inserted_at)
```

### Duplicate behavior

```text
Duplicate valid webhook must return success to Paystack.
Duplicate valid webhook must not enqueue duplicate verification work.
Duplicate valid webhook must not update Order, PaymentAttempt, TicketIssue, Attendee, or inventory state.
Duplicate valid webhook may update duplicate_seen telemetry/metrics if such metrics exist.
```

---

## 9. Controller Contract

The controller must do the minimum safe work:

```text
Read raw request body.
Extract X-Paystack-Signature header.
Verify signature using WebhookVerifier.
Compute payload_hash.
Decode JSON only after preserving raw body.
Extract safe metadata.
Apply Redis dedupe if Redis is healthy.
Persist PaymentEvent through the approved Sales/Ash action.
Enqueue PaystackWebhookWorker for valid new events.
Return quickly.
```

### Response rules

Use project conventions, but prefer:

```text
Valid new event stored + worker enqueued: 200 or 202
Valid duplicate event: 200
Invalid signature: 401 or 400, no worker
Malformed JSON with valid/unchecked signature: 400, no worker
Internal transient error before persistence: 500 so Paystack can retry
```

Do not return raw exception messages.

### Timeout rule

The endpoint must not perform network calls, transaction verification, issuance, or long DB work. It should be safe under webhook bursts.

---

## 10. Worker Contract for This Slice

Create the worker shell if it does not exist, but keep it ingestion-only.

```text
Module: FastCheck.Workers.PaystackWebhookWorker
Queue: payments
Uniqueness: by payment_event_id
Input: payment_event_id
```

Allowed worker behavior in VS-07A:

```text
Load PaymentEvent.
Mark processing_started only if the existing state matrix/action requires it.
Emit telemetry.
Stop before transaction verification.
Optionally leave a clear TODO/next-step boundary for VS-07B.
```

Forbidden worker behavior in VS-07A:

```text
No Paystack Verify Transaction API call.
No PaymentAttempt verified_success.
No Order paid states.
No checkout/session paid states.
No Redis inventory consume/release.
No TicketIssue creation.
No Attendee creation.
No DeliveryAttempt creation.
No WhatsApp send.
```

If the project prefers workers to do all processing, this worker may simply be enqueued and remain minimal until VS-07B.

---

## 11. Security, PII, and Logging Rules

Never log:

```text
raw_payload
authorization_url
access_code
Paystack secret key
X-Paystack-Signature value
buyer phone
buyer email
customer name
plaintext tokens
full provider response bodies
```

Allowed logs:

```text
provider = paystack
event_type
provider_reference_hash or masked reference
payload_hash
signature_valid boolean
processing_status
payment_event_id
correlation_id/request_id
latency_ms
```

Raw provider payload access:

```text
admin/system only
operator summarized view only
customer never
```

Signature comparison:

```text
Use constant-time comparison.
Do not use plain == for secrets/signatures if the language/library provides secure compare.
```

---

## 12. Performance and Scaling Review

### Data layering

```text
Hot data:
  Redis SETNX dedupe key for webhook duplicate suppression.

Warm data:
  Optional short-lived metrics/counters only if already present.

Cold durable data:
  Postgres PaymentEvent rows.
```

### Redis structures

```text
sales:payments:paystack:webhook:{dedupe_key} -> string key with SETNX behavior, TTL 24h minimum
```

### Required indexes

```text
sales_payment_events unique(provider, provider_event_id)
sales_payment_events unique(provider, payload_hash) where provider_event_id is null
sales_payment_events index(provider_reference)
sales_payment_events index(processing_status, inserted_at)
sales_payment_events index(received_at) if high-volume cleanup/reporting needs it
```

### Scaling rules

```text
No Paystack verification HTTP call in the webhook request path.
No ticket issuance in the webhook request path.
No order dashboard query in the webhook request path.
No large table scan when deduping.
Use Oban for processing.
Keep endpoint safe under duplicate bursts.
Use PgBouncer transaction mode compatibility: avoid long transactions and session-level DB assumptions.
```

### Cache invalidation

```text
No public cache invalidation is required in VS-07A.
Do not broadcast customer-facing payment updates yet.
Payment status changes happen in VS-07B/VS-07C.
```

### PubSub

```text
No customer-facing PubSub broadcast in VS-07A.
Telemetry event only: [:fastcheck, :sales, :payment, :webhook_received]
Optional duplicate event: [:fastcheck, :sales, :payment, :webhook_duplicate]
Optional rejected event: [:fastcheck, :sales, :payment, :webhook_rejected]
```

---

## 13. RED/GREEN Test Plan

Write tests RED first. Then make the smallest safe implementation changes needed for GREEN.

### Group A — Valid signed webhook ingestion

RED tests must fail if:

```text
A valid signed Paystack payload is rejected.
The endpoint cannot access the raw body needed for signature verification.
A valid event does not create a PaymentEvent.
PaymentEvent does not persist provider, event_type, provider_reference, payload_hash, signature_valid, received_at, and processing_status.
A valid new event does not enqueue PaystackWebhookWorker.
The endpoint performs transaction verification before returning.
```

GREEN requires:

```text
Valid signed payload returns 200/202.
Exactly one PaymentEvent is created.
Exactly one PaystackWebhookWorker job is enqueued.
No Order, PaymentAttempt, TicketIssue, Attendee, DeliveryAttempt, or inventory state is changed.
```

---

### Group B — Signature verification

RED tests must fail if:

```text
Missing X-Paystack-Signature is accepted.
Invalid X-Paystack-Signature is accepted.
Signature verification uses parsed/re-encoded JSON instead of the preserved raw body when raw-body verification is required.
Invalid signature enqueues a worker.
Invalid signature mutates PaymentAttempt, Order, TicketIssue, Attendee, or inventory state.
```

GREEN requires:

```text
Missing/invalid signature returns a safe rejection response.
No verification worker is enqueued.
No business state is mutated.
Rejected event is either not persisted or persisted only as a safe restricted audit record according to the accepted security policy.
Logs do not include the signature value or raw payload.
```

---

### Group C — Malformed payload handling

RED tests must fail if:

```text
Malformed JSON crashes the endpoint.
Malformed JSON returns raw exception text.
Malformed JSON creates a normal queued PaymentEvent.
Malformed JSON enqueues a worker.
Malformed JSON logs the raw payload.
```

GREEN requires:

```text
Malformed payload returns 400 or equivalent safe error.
No worker is enqueued.
No payment/order/ticket/inventory state changes occur.
Telemetry/logging is redacted.
```

---

### Group D — Duplicate webhook delivery

RED tests must fail if:

```text
The same provider_event_id creates multiple PaymentEvents.
The same payload_hash fallback creates multiple PaymentEvents when provider_event_id is absent.
Duplicate events enqueue duplicate workers.
Duplicate valid events return a provider-visible failure that would cause unnecessary retries.
Duplicate events mutate payment/order/ticket/inventory state.
```

GREEN requires:

```text
Duplicate valid webhook returns 200.
Only one durable PaymentEvent exists for the dedupe key.
Only one worker is enqueued for the dedupe key.
Redis dedupe and DB unique constraints agree.
```

---

### Group E — Redis dedupe degraded behavior

RED tests must fail if:

```text
Redis unavailable causes accepted webhook data to be silently dropped.
Redis unavailable causes duplicate workers without DB protection.
Redis unavailable creates inconsistent PaymentEvent rows.
```

GREEN requires:

```text
DB uniqueness remains the durable dedupe fallback.
Endpoint either stores the event and enqueues safely, or returns a transient 500 before persistence so Paystack can retry.
No accepted webhook is lost silently.
A clear error is logged without secrets or raw payload.
```

---

### Group F — PaymentEvent policy and raw payload access

RED tests must fail if:

```text
operator can read raw_payload.
customer_session can read PaymentEvent.
customer_session can create PaymentEvent.
admin/operator list exposes raw payload by default.
raw payload or PII appears in logs.
```

GREEN requires:

```text
system can create PaymentEvent.
admin can read restricted details according to policy.
operator only sees summarized/safe fields.
customer_session cannot read or mutate PaymentEvent.
Raw payload is restricted and never logged.
```

---

### Group G — Worker enqueue contract

RED tests must fail if:

```text
Worker is enqueued without payment_event_id.
Worker uniqueness does not prevent duplicate jobs for the same event.
Worker uses provider_reference alone as uniqueness key.
Worker runs verification logic in this slice.
Worker mutates payment/order/ticket/inventory state.
```

GREEN requires:

```text
Worker input is payment_event_id.
Worker uniqueness is by payment_event_id.
Worker is safe under duplicate enqueue attempts.
Worker does not verify or mutate paid/ticket/inventory state in VS-07A.
```

---

### Group H — Boundary creep tests

RED tests must fail if VS-07A adds or calls:

```text
FastCheck.Payments.Paystack.TransactionVerifier.verify
Paystack Verify Transaction API
Order.mark_paid_unverified
Order.mark_paid_verified
PaymentAttempt.mark_verified_success
CheckoutSession.paid transition
ReservationLedger.consume
ReservationLedger.release
FastCheck.Tickets.Issuer.issue_order
Attendee insert/update
TicketIssue create/mark_issued
DeliveryAttempt create
WhatsApp/Meta client
scanner/mobile sync update
admin manual-review UI
```

GREEN requires:

```text
VS-07A remains ingestion-only.
Only PaymentEvent ingestion and worker enqueue behavior are added.
```

---

## 14. Failure Modes and Required Handling

| Failure mode | Required behavior |
|---|---|
| Missing signature | Reject safely; no worker; no business mutation. |
| Invalid signature | Reject safely; optional restricted audit only; no worker. |
| Malformed JSON | Safe 400; no worker; no business mutation. |
| Duplicate valid webhook | Return success; no duplicate durable event/job. |
| Redis dedupe unavailable | Use DB uniqueness fallback or return transient failure before persistence. |
| DB unavailable before persistence | Return 500 so Paystack retries. |
| Oban enqueue fails after event persisted | Mark/leave event retryable; return strategy must be explicit. Prefer transaction/multi if available. |
| Webhook arrives before PaymentAttempt exists | Store event as unmatched/stored; VS-07B/VS-07C handles retry/manual review. Do not drop. |
| Webhook arrives after checkout expired | Store event; do not decide fulfillment here. VS-07C applies payment-after-expiry policy. |
| Provider sends unknown event type | Store safely if signed; do not verify/fulfill; worker can later ignore or mark unsupported. |
| Payload too large | Reject with safe 413/400 according to endpoint config; no raw logging. |

---

## 15. Acceptance Criteria

The slice is complete when:

```text
Paystack webhook route exists and is tested.
Raw body is available for signature verification.
WebhookVerifier is used; signature comparison is constant-time.
Valid signed webhook creates exactly one PaymentEvent.
Duplicate signed webhook does not create duplicate PaymentEvents or jobs.
Valid new webhook enqueues PaystackWebhookWorker.
Invalid signature does not enqueue worker or mutate business state.
Malformed payload does not crash the endpoint.
PaymentEvent raw payload access is restricted.
Logs redact raw payload, signature, secrets, access_code, authorization_url, phone, email, and tokens.
Telemetry uses approved naming.
No Paystack transaction verification is implemented.
No paid/order/ticket/attendee/scanner/inventory/WhatsApp mutation is implemented.
All RED/GREEN tests pass.
```

---

## 16. Recommended Implementation Sequence

```text
1. Inspect current webhook/body parser/router patterns.
2. Add tests for valid signed payload and invalid signature.
3. Add raw body preservation if missing.
4. Wire route/controller with minimal logic.
5. Add or patch Paystack WebhookVerifier usage.
6. Add PaymentEvent store action usage.
7. Add Redis + DB dedupe behavior.
8. Add Oban worker enqueue with uniqueness.
9. Add malformed JSON and duplicate delivery tests.
10. Add policy/security/log redaction tests.
11. Add boundary creep tests.
12. Run focused tests, then broader payment/sales test subset.
```

Do not begin VS-07B behavior in this pack.

---

## 17. TOON Coding-Agent Prompt

| Field | Content |
|---|---|
| Task | Implement `VS-07A — Paystack Webhook Ingestion` for FastCheck Sales. |
| Objective | Add a secure, idempotent Paystack webhook ingestion endpoint that verifies signatures, stores `PaymentEvent`, dedupes duplicate provider deliveries, enqueues `PaystackWebhookWorker`, and returns quickly without performing transaction verification or ticket/payment state mutation. |
| Output | Create or patch `lib/fastcheck_web/controllers/webhooks/paystack_controller.ex`, webhook route config, raw body preservation configuration, `lib/fastcheck/payments/paystack/webhook_verifier.ex` only if VS-06A left gaps, optional `webhook_event_parser.ex`, optional `event_dedupe.ex`, `lib/fastcheck/workers/paystack_webhook_worker.ex`, and focused tests under `test/fastcheck_web/controllers/webhooks/` and `test/fastcheck/payments/paystack/`. |
| Note | Use existing project conventions first. Preserve raw body for signature verification. Verify `X-Paystack-Signature` with HMAC SHA512 using Paystack secret and constant-time comparison. Do not log raw payload, signature, access_code, authorization_url, secrets, PII, or tokens. Store signed events as `FastCheck.Sales.PaymentEvent` with provider `paystack`, `provider_event_id`, `provider_reference`, `event_type`, `signature_valid`, `payload_hash`, `raw_payload`, `received_at`, and `processing_status`. Use Redis SETNX key `sales:payments:paystack:webhook:{dedupe_key}` with TTL >= 24h plus DB unique indexes `unique(provider, provider_event_id)` and `unique(provider, payload_hash) where provider_event_id is null`. Enqueue worker by `payment_event_id`; worker uniqueness must be by `payment_event_id`. Required indexes: `sales_payment_events(provider_reference)`, `sales_payment_events(processing_status, inserted_at)`. No Paystack verify API, no `mark_paid_verified`, no `PaymentAttempt` mutation, no `Order` paid transition, no `ReservationLedger.consume/release`, no ticket issuance, no Attendee mutation, no scanner sync, no WhatsApp/Meta behavior. Telemetry: `[:fastcheck, :sales, :payment, :webhook_received]`, optional duplicate/rejected events. Keep endpoint short and safe under duplicate bursts. |

---

## 18. Copy-Paste Prompt for Coding Agent

```text
You are implementing FastCheck Sales slice VS-07A — Paystack Webhook Ingestion.

Goal:
Add a secure, idempotent Paystack webhook ingestion endpoint that verifies signatures, stores PaymentEvent rows, dedupes duplicate provider deliveries, enqueues PaystackWebhookWorker, and returns quickly.

Important boundaries:
- This slice is ingestion only.
- Do not verify Paystack transactions in this slice.
- Do not mark PaymentAttempt verified_success.
- Do not mark Order paid_unverified or paid_verified.
- Do not mutate CheckoutSession to paid.
- Do not consume/release/re-reserve Redis inventory.
- Do not issue tickets.
- Do not create or update Attendees.
- Do not create DeliveryAttempt.
- Do not touch scanner/mobile sync.
- Do not add WhatsApp/Meta behavior.

Before coding:
1. Inspect existing Phoenix router/controller conventions.
2. Inspect raw body preservation/body_reader conventions.
3. Inspect Paystack WebhookVerifier from VS-06A.
4. Inspect PaymentEvent Ash resource/actions/policies from VS-01C/VS-01F.
5. Inspect Oban worker uniqueness conventions.
6. Inspect Redis helper conventions.
7. Inspect telemetry/log redaction helpers.

Expected implementation:
- Add POST /webhooks/paystack or the existing project-equivalent route.
- Preserve raw request body for signature verification.
- Verify X-Paystack-Signature using HMAC SHA512 and constant-time comparison.
- Compute SHA256 payload_hash from raw body bytes.
- Decode JSON safely after raw body is preserved.
- Extract provider_event_id if present, provider_reference from data.reference, and event_type from event.
- Store a FastCheck.Sales.PaymentEvent with provider paystack, event metadata, signature_valid, payload_hash, restricted raw_payload, received_at, and processing_status.
- Dedupe using Redis SETNX key sales:payments:paystack:webhook:{dedupe_key} with TTL >= 24h and DB unique indexes.
- Enqueue FastCheck.Workers.PaystackWebhookWorker with payment_event_id only for valid new events.
- Return 200/202 for valid new events, 200 for duplicates, safe rejection for invalid signatures, safe 400 for malformed payloads, and 500 only when retry is required.

Tests must be RED first, then GREEN:
- valid signed webhook creates one PaymentEvent and one worker job
- missing/invalid signature rejected with no worker and no business mutation
- raw-body signature verification works
- malformed JSON is safe
- duplicate provider_event_id creates no duplicate event/job
- payload_hash fallback dedupes when provider_event_id is absent
- Redis unavailable does not silently drop accepted events
- operator/customer_session cannot read raw payload
- logs redact raw payload, signature, secrets, PII, access_code, authorization_url, tokens
- boundary tests prove no verification, paid state, inventory consume/release, ticket issuance, Attendee, scanner, DeliveryAttempt, WhatsApp, or admin UI behavior was added

Keep code minimal. Use existing conventions. Do not over-engineer.
```

---

## 19. Human Review Checklist

Use this before marking VS-07A Done:

```text
[ ] Route/controller exists and matches project conventions.
[ ] Raw body preservation is implemented and tested.
[ ] Signature verification uses the VS-06A boundary and constant-time compare.
[ ] Invalid signatures do not enqueue workers.
[ ] Valid signed event creates one PaymentEvent.
[ ] Duplicate event creates no duplicate PaymentEvent or worker job.
[ ] PaymentEvent raw_payload is restricted by policy.
[ ] Redis dedupe TTL is >= 24h.
[ ] DB unique indexes protect duplicate provider_event_id and payload_hash fallback.
[ ] PaystackWebhookWorker is enqueued by payment_event_id.
[ ] Worker does not verify transactions in this slice.
[ ] Controller performs no Paystack verification HTTP call.
[ ] No PaymentAttempt verified_success / Order paid state mutation was added.
[ ] No Redis inventory consume/release/reserve mutation was added.
[ ] No ticket issuance or Attendee mutation was added.
[ ] No scanner/mobile sync mutation was added.
[ ] No WhatsApp/Meta behavior was added.
[ ] Logs are redacted.
[ ] Telemetry names match VS-21A conventions.
[ ] All focused tests pass.
```

---

## 20. Success Looks Like

A reviewer can replay Paystack webhook scenarios and see this behavior:

```text
Valid event -> stored PaymentEvent -> one Oban job -> quick HTTP response.
Duplicate event -> idempotent success -> no duplicate durable/worker side effects.
Invalid signature -> rejected safely -> no business mutation.
Malformed payload -> rejected safely -> no crash/no raw logs.
Webhook before local payment attempt exists -> stored for later verification/retry -> not dropped.
```

And most importantly:

```text
No customer receives ticket value from a webhook payload alone.
```

---

## 21. Next Slice

```text
VS-07B — Paystack Transaction Verification
```
