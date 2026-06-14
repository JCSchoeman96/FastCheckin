# FastCheck Sales Feature Planning Pack — VS-07B Paystack Transaction Verification

**Pack ID:** `0023_VS-07B_paystack-transaction-verification`  
**Slice:** `VS-07B`  
**Slice name:** Paystack Transaction Verification  
**Version:** `v1.0`  
**Date:** 2026-06-13  
**Repository path:** `docs/fastcheck_sales/feature_packs/0023_VS-07B_paystack-transaction-verification/`  
**Status:** Implementation planning pack — implementation allowed inside this slice only  
**Primary area:** Payments / Verification / Ash State / Oban / Idempotency  
**Depends on:** VS-07A, VS-06B, VS-06C, VS-06A, VS-05, VS-04B, VS-01C, VS-01F, VS-01G, VS-00A, VS-00B, VS-00C, VS-21A  
**Blocks:** VS-07C, VS-09A, VS-12, VS-19, VS-21B, VS-22  
**Source docs:**

```text
docs/fastcheck_sales/SOURCE_DOCS/FastCheck_Sales_Ash_Atlas_Planning_Pack_v0.2.3_HARDENED.md
docs/fastcheck_sales/SOURCE_DOCS/FastCheck_Sales_Vertical_Slice_Roadmap_v1.1.3_HARDENED.md
```

---

## 1. Purpose

This pack instructs a coding agent to implement **server-side Paystack transaction verification**.

The goal is to take a known Paystack `provider_reference`, call the approved Paystack verification boundary, compare the provider result against FastCheck durable state, and apply only safe payment verification state transitions.

Critical principle:

```text
Webhook ingestion is not payment verification.
Verification is not ticket issuance.
Verification is not refund handling.
Verification must not consume/release inventory directly.
```

VS-07B owns trust classification:

```text
provider status check
amount check
currency check
reference check
known local PaymentAttempt ownership check
safe idempotent verified-success handling
```

VS-07C owns the messy downstream failure/outcome handling:

```text
duplicate payment event handling
amount/currency/reference mismatch workflows
unmatched events
expired checkout recovery
manual-review transition policy
payment-after-expiry inventory decision
```

---

## 2. Ultimate Outcome

After VS-07B is complete:

```text
VerifyPaymentWorker can verify a Paystack transaction by provider reference or payment_attempt_id.
FastCheck calls Paystack Verify Transaction from the backend only.
PaymentAttempt moves through verification_started into verified_success only when provider status, amount, currency, and reference all match.
Order may move to paid_verified only for a valid active order/checkout path that still satisfies the approved VS-05 state matrix.
CheckoutSession may move to paid only when the session is still active and the hold is still eligible.
PaymentEvent processing state is updated when verification was triggered from a webhook event.
Duplicate worker execution is idempotent.
Mismatch/unmatched/expired cases are safely classified and left for VS-07C-specific outcome handling.
No ticket is issued, no Attendee is created, and no scanner-visible state changes.
Logs and telemetry are redacted and correlation-safe.
```

The system is then ready for VS-07C to implement failure, mismatch, duplicate, unmatched, expired-checkout, and manual-review outcomes.

---

## 3. Scope

### In scope

```text
Add or finalize FastCheck.Payments.Paystack.TransactionVerifier usage from VS-06A.
Add a payment verification orchestration module if not already present.
Add or finalize FastCheck.Workers.VerifyPaymentWorker.
Verify Paystack transaction by provider_reference from backend.
Load local PaymentAttempt by provider + provider_reference.
Load owning Order and CheckoutSession needed for state preconditions.
Compare Paystack result status, reference, amount, and currency to local durable values.
Update PaymentAttempt verification state through named Ash actions only.
Update PaymentEvent processing state when verification was triggered by a PaymentEvent.
Update Order to paid_verified only when all checks pass and VS-05 order preconditions are still valid.
Update CheckoutSession to paid only when all checks pass and session/hold preconditions are still valid.
Record StateTransition rows for every local payment/order/session state change.
Store sanitized raw_verify_response according to VS-00B rules.
Add RED/GREEN tests for success, mismatch classification, failed provider status, idempotency, retry, policies, and boundary creep.
Add telemetry and redacted structured logs.
```

### Out of scope

```text
No Paystack webhook controller changes except worker enqueue integration gaps discovered from VS-07A.
No webhook signature verification changes except missing test wiring.
No Paystack transaction initialization changes.
No customer-facing payment status page.
No payment-after-expiry inventory decision.
No inventory consume, release, reserve, or re-reserve.
No ticket issuance.
No Attendee creation or mutation.
No scanner/mobile sync changes.
No DeliveryAttempt creation.
No WhatsApp/Meta behavior.
No refund handling.
No admin manual-review UI.
No provider refund API.
No broad reconciliation backfill job.
```

---

## 4. Required Pre-Implementation Discovery

Before changing code, the agent must inspect the repository and document findings in the final report:

```text
Existing FastCheck.Payments.Paystack.TransactionVerifier API from VS-06A.
Existing Paystack initialization module and provider_reference/idempotency conventions from VS-06B.
Existing PaymentAttempt Ash actions and policies from VS-01C/VS-01F.
Existing PaymentEvent Ash actions and processing_status values from VS-07A.
Existing Order and CheckoutSession state actions from VS-05.
Existing StateTransition helper/action conventions from VS-00A/VS-01B/VS-05.
Existing Oban queue and uniqueness conventions.
Existing Mox/BYPASS/Req test strategy for provider HTTP calls.
Existing telemetry/log redaction helper conventions from VS-21A.
Existing Repo.transaction and row-locking conventions.
Existing Redis helper usage for webhook dedupe, but do not add inventory mutation here.
```

Do not invent new conventions when the project already has a clear pattern.

---

## 5. Provider Behavior Notes

Use official Paystack behavior as provider input, but keep FastCheck business authority internal.

Paystack verification expectations:

```text
Verification is done from the server using the transaction reference.
The Verify Transaction API confirms the transaction status.
The transaction response must be inspected from the response data, not inferred from HTTP success alone.
Amount must be checked before value delivery.
Amounts are represented in currency subunits.
Currency uses ISO 4217 currency codes.
```

FastCheck verification rules:

```text
Provider reference must equal PaymentAttempt.provider_reference.
Provider status must be success before local verified_success.
Provider amount must equal PaymentAttempt.amount_cents and Order.total_amount_cents.
Provider currency must equal PaymentAttempt.currency and Order.currency.
Provider integration/domain/test-live mode should match configured environment where available.
Provider customer payload is not the identity authority; local order/payment attempt ownership is the authority.
Webhook payload alone must never deliver value.
```

---

## 6. Domain and Boundary Details

### Ash domain

```text
FastCheck.Sales
```

### Ash resources touched

```text
FastCheck.Sales.PaymentAttempt
FastCheck.Sales.PaymentEvent
FastCheck.Sales.Order
FastCheck.Sales.CheckoutSession
FastCheck.Sales.StateTransition
```

### Ash resources explicitly forbidden from mutation

```text
FastCheck.Sales.OrderLine
FastCheck.Sales.TicketOffer
FastCheck.Sales.TicketIssue
FastCheck.Sales.DeliveryAttempt
FastCheck.Sales.Conversation
```

### Existing Ecto / scanner resources forbidden from mutation

```text
FastCheck.Attendees
FastCheck.Attendees.Scan
FastCheck.Attendees.Reconciliation
FastCheck.Events.Sync
Existing Android mobile API endpoints
Existing scanner routes
Existing scanner hot path
```

### Plain modules expected

Use actual repository names if they differ. Preferred names:

```text
lib/fastcheck/payments/paystack/transaction_verifier.ex
lib/fastcheck/payments/paystack/verification_result.ex
lib/fastcheck/payments/paystack/payment_verification.ex
lib/fastcheck/payments/paystack/payload_sanitizer.ex
lib/fastcheck/workers/verify_payment_worker.ex
```

### Preferred test files

Use project conventions. If no convention exists, prefer:

```text
test/fastcheck/payments/paystack/transaction_verifier_test.exs
test/fastcheck/payments/paystack/payment_verification_test.exs
test/fastcheck/workers/verify_payment_worker_test.exs
test/fastcheck/payments/paystack/payment_verification_state_test.exs
test/fastcheck/payments/paystack/payment_verification_idempotency_test.exs
test/fastcheck/payments/paystack/payment_verification_security_test.exs
test/fastcheck/payments/paystack/payment_verification_boundary_test.exs
```

---

## 7. Verification Workflow Contract

Preferred orchestration shape:

```text
VerifyPaymentWorker
  -> FastCheck.Payments.Paystack.PaymentVerification.verify_attempt(payment_attempt_id, opts)
      -> load PaymentAttempt + Order + CheckoutSession
      -> return idempotent success if PaymentAttempt already verified_success and Order already paid_verified
      -> mark PaymentAttempt verification_started through named action
      -> call FastCheck.Payments.Paystack.TransactionVerifier.verify(provider_reference) outside DB transaction
      -> sanitize provider response before persistence/logging
      -> reload/lock PaymentAttempt + Order + CheckoutSession
      -> compare provider status/reference/amount/currency
      -> apply named Ash state actions
      -> mark PaymentEvent processed/failed/unmatched if called from PaymentEvent
      -> emit telemetry
```

Rules:

```text
Do not hold a DB transaction open while the Paystack HTTP request is running.
Use Oban uniqueness by payment_attempt_id or provider_reference.
Use row locking or optimistic locking when applying final state transitions.
Use named Ash actions; do not Repo.update status columns directly.
Every state change must append StateTransition.
Provider timeout/network failure is retryable and must not mark payment failed permanently unless policy says so.
Business mismatch is not retryable as transient; classify safely and leave final manual-review handling to VS-07C.
Duplicate worker execution must not duplicate transitions or downgrade verified state.
```

---

## 8. State Transition Contract

### PaymentAttempt allowed transitions in this slice

```text
initialized -> verification_started
authorization_url_sent -> verification_started
webhook_received -> verification_started
verification_started -> verified_success
verification_started -> verified_amount_mismatch
verification_started -> verified_currency_mismatch
verification_started -> failed
verification_started -> manual_review
verified_success -> verified_success       # idempotent no-op only
verified_amount_mismatch -> verified_amount_mismatch  # idempotent no-op only
verified_currency_mismatch -> verified_currency_mismatch  # idempotent no-op only
failed -> verification_started             # retry only for retryable provider/network failures
manual_review -> manual_review             # no-op only; VS-07C owns recovery
```

### Order allowed transitions in this slice

```text
awaiting_payment -> paid_verified          # only when all provider checks pass and checkout/session preconditions are valid
payment_pending -> paid_verified           # only when all provider checks pass and checkout/session preconditions are valid
paid_unverified -> paid_verified           # only when all provider checks pass and checkout/session preconditions are valid
paid_verified -> paid_verified             # idempotent no-op only
expired -> expired                         # no direct recovery here; VS-07C owns payment-after-expiry outcome
manual_review -> manual_review             # no recovery here
cancelled -> cancelled                     # no recovery here
refunded -> refunded                       # no recovery here
```

### CheckoutSession allowed transitions in this slice

```text
payment_link_sent -> paid                  # only when all provider checks pass and session/hold preconditions are valid
payment_started -> paid                    # only when all provider checks pass and session/hold preconditions are valid
paid -> paid                               # idempotent no-op only
expired -> expired                         # VS-07C owns late verified payment handling
released -> released                       # no direct recovery here
manual_review -> manual_review             # no recovery here
```

### PaymentEvent allowed transitions in this slice

```text
stored -> processing_started
processing_started -> processed
processing_started -> unmatched
processing_started -> failed
processing_started -> duplicate
processed -> processed                     # idempotent no-op only
duplicate -> duplicate                     # idempotent no-op only
unmatched -> unmatched                     # VS-07C owns retry/manual-review policy
failed -> processing_started               # retry only for transient provider/local errors
```

Rules:

```text
No transition may skip PaymentAttempt verification_started unless an existing action intentionally combines it with audit metadata.
Order paid_verified requires verified PaymentAttempt ownership and provider checks.
CheckoutSession paid must not release or consume inventory here.
Expired checkout with verified payment must not issue automatically.
Mismatch outcomes must not mark Order paid_verified.
```

---

## 9. Verification Matching Rules

### Required checks before `PaymentAttempt.verified_success`

```text
provider == paystack
local PaymentAttempt exists for provider_reference
local PaymentAttempt belongs to the loaded Order
Paystack verification response is successful at the API-call level
Paystack data.status == success
Paystack data.reference == PaymentAttempt.provider_reference
Paystack data.amount == PaymentAttempt.amount_cents
Paystack data.amount == Order.total_amount_cents
Paystack data.currency == PaymentAttempt.currency
Paystack data.currency == Order.currency
Paystack response is from the expected integration/environment where available
```

### Required checks before `Order.paid_verified`

```text
PaymentAttempt has just reached verified_success or was already verified_success.
Order state is awaiting_payment, payment_pending, or paid_unverified.
Order total_amount_cents and currency match verified PaymentAttempt.
CheckoutSession is eligible according to VS-05 state matrix.
No terminal Order state is being overwritten.
StateTransition is appended with correlation_id/idempotency_key/provider_reference.
```

### Required checks before `CheckoutSession.paid`

```text
CheckoutSession belongs to the same Order.
CheckoutSession state is payment_link_sent or payment_started.
CheckoutSession is not expired, released, failed, or manual_review.
No inventory consume/release/re-reserve happens in this slice.
```

---

## 10. Error and Classification Rules

| Case | Required VS-07B behavior |
|---|---|
| Provider status `success` and all fields match | Mark PaymentAttempt `verified_success`; mark active Order `paid_verified`; mark eligible CheckoutSession `paid`; record transitions. |
| Provider status not `success` | Mark/keep PaymentAttempt `failed` or safe provider-status classification; do not mark Order paid. |
| Amount mismatch | Mark PaymentAttempt `verified_amount_mismatch`; do not mark Order paid; leave final manual-review workflow to VS-07C. |
| Currency mismatch | Mark PaymentAttempt `verified_currency_mismatch`; do not mark Order paid; leave final manual-review workflow to VS-07C. |
| Reference mismatch | Mark PaymentAttempt `manual_review` or provider-reference mismatch classification; do not mark Order paid. |
| No local PaymentAttempt | Mark PaymentEvent `unmatched` if triggered from event; do not create Order/PaymentAttempt here. |
| Checkout/session expired but provider payment verified | Mark PaymentAttempt `verified_success`; do not issue ticket; do not consume inventory; VS-07C handles payment-after-expiry outcome. |
| Duplicate worker for verified_success | Return idempotent success; do not duplicate transitions or provider calls if local verified state is final. |
| Provider timeout/network failure | Retry through Oban; do not permanently fail payment on a transient network error. |
| Malformed provider response | Mark retryable failed or manual_review according to existing policy; never mark paid. |

---

## 11. Implementation Boundaries and Avoid List

### Must use

```text
FastCheck.Payments.Paystack.TransactionVerifier.verify/1 or repository-equivalent boundary
FastCheck.Payments.Paystack.PayloadSanitizer or repository-equivalent sanitizer
FastCheck.Sales named Ash actions for PaymentAttempt, PaymentEvent, Order, CheckoutSession, and StateTransition
FastCheck.Workers.VerifyPaymentWorker with Oban uniqueness
Telemetry/log redaction helpers from VS-21A
```

### Must avoid

```text
Do not call Paystack HTTP from Ash resource actions.
Do not verify payments directly in webhook controller.
Do not rely on webhook payload as proof of payment.
Do not update status fields with Repo.update_all or direct changesets.
Do not store or log plaintext access_code, authorization_url, secret key, raw payload, raw verify response, phone, email, or tokens.
Do not consume/release/re-reserve Redis inventory.
Do not create TicketIssue.
Do not create or mutate Attendee.
Do not bump event sync versions.
Do not send WhatsApp/email.
Do not create DeliveryAttempt.
Do not implement refund/revocation.
```

---

## 12. RED/GREEN Test Plan

Tests must be written RED first, then made GREEN by implementation.

### RED tests — required failures before implementation

```text
Valid Paystack verification response does not move PaymentAttempt to verified_success.
Valid Paystack verification response does not move active Order to paid_verified.
PaymentAttempt can be marked verified_success without Paystack server-side verification.
Order can be marked paid_verified from webhook payload only.
Provider status failed/abandoned/pending can mark Order paid_verified.
Amount mismatch can mark Order paid_verified.
Currency mismatch can mark Order paid_verified.
Reference mismatch can mark Order paid_verified.
No local PaymentAttempt creates or mutates an Order.
Expired/released checkout consumes inventory or issues ticket during verification.
Duplicate VerifyPaymentWorker creates duplicate transitions or downgrades verified_success.
Transient provider timeout permanently fails the payment.
Operator/customer_session can trigger verification directly.
Operator/customer_session can read raw_verify_response.
Logs include provider secret, access_code, authorization_url, raw payload, raw verify response, phone, email, or tokens.
Verification path creates TicketIssue, Attendee, DeliveryAttempt, WhatsApp message, scanner sync bump, or Redis inventory mutation.
```

### GREEN tests — required success after implementation

```text
Given PaymentAttempt + active Order + eligible CheckoutSession, provider success with matching amount/currency/reference marks PaymentAttempt verified_success.
The same success case marks Order paid_verified and CheckoutSession paid through named actions only.
StateTransition rows are appended for each state change with provider_reference and correlation metadata.
Provider status not success does not mark Order paid_verified.
Amount mismatch sets verified_amount_mismatch and leaves Order unpaid.
Currency mismatch sets verified_currency_mismatch and leaves Order unpaid.
Reference mismatch moves to manual_review/classification and leaves Order unpaid.
Unmatched provider_reference marks the PaymentEvent unmatched when called from an event.
Expired checkout with provider success does not issue, consume inventory, or mark fulfillment queued.
Duplicate worker execution is idempotent and creates no duplicate transitions.
Provider timeout is retryable through Oban.
Malformed provider response is safe and never marks paid.
Raw verify response is stored only in restricted/sanitized form according to VS-00B.
Only system actor/worker path can perform verification transitions.
Boundary tests prove no ticket, attendee, scanner, inventory, delivery, WhatsApp, or refund side effects exist.
```

---

## 13. Acceptance Criteria

VS-07B is Done only when all criteria are true:

```text
VerifyPaymentWorker exists or is finalized and uses the payments queue.
Worker uniqueness prevents duplicate verification work by payment_attempt_id/provider_reference.
Paystack TransactionVerifier is called from plain module/worker code, not Ash resource actions.
HTTP provider call is outside DB transaction.
PaymentAttempt verification transitions use named Ash actions.
Order paid_verified transition uses named Ash action and only all-checks-pass preconditions.
CheckoutSession paid transition uses named Ash action and only active-session preconditions.
PaymentEvent processing transitions use named Ash actions where relevant.
Every state change appends StateTransition.
Amount, currency, reference, provider status, and local ownership checks are enforced.
Mismatch/unmatched/expired cases do not issue tickets and are ready for VS-07C.
No Redis inventory mutation exists.
No Attendee/scanner/mobile-sync mutation exists.
No WhatsApp/DeliveryAttempt side effect exists.
All RED/GREEN tests pass.
Logs and telemetry are redacted.
Final report documents exact touched files, actions added, tests added, and remaining VS-07C handoff cases.
```

---

## 14. Performance and Scaling Review

### Data layer classification

```text
Hot data:
  Oban uniqueness and optional Redis/provider-reference dedupe keys if already used.

Warm data:
  Optional admin/payment status cache invalidation after paid_verified.

Cold durable data:
  PaymentAttempt
  PaymentEvent
  Order
  CheckoutSession
  StateTransition
```

### Required indexes to verify

```text
sales_payment_attempts unique(provider, provider_reference)
sales_payment_attempts index(sales_order_id, status)
sales_payment_attempts index(provider, status)
sales_payment_attempts index(last_verified_at)
sales_payment_events index(provider_reference)
sales_payment_events index(processing_status, inserted_at)
sales_orders index(event_id, status, inserted_at)
sales_orders index(status, fulfillment_queued_at)
sales_checkout_sessions unique(sales_order_id)
sales_checkout_sessions index(status, expires_at)
sales_state_transitions index(entity_type, entity_id, inserted_at)
```

### Concurrency rules

```text
Use Oban uniqueness by payment_attempt_id or provider_reference.
Use lock_version or row lock when applying final verification state.
Duplicate verification workers must return idempotent success for already verified attempts.
Do not run broad queries by status without indexed pagination.
Do not verify inside request/webhook controller.
Do not hold DB transaction while waiting on Paystack HTTP.
Throttle verification worker concurrency to protect provider/API and DB pools.
```

### Cache and PubSub rules

```text
No inventory cache invalidation in VS-07B.
No offer availability PubSub in VS-07B.
On Order paid_verified, invalidate admin/order/payment dashboard cache if such cache exists.
On Order paid_verified, broadcast internal admin/status update only if existing PubSub conventions exist.
No customer ticket/delivery PubSub in this slice.
```

### Telemetry events

Use exact project conventions if already defined. Preferred event names:

```text
[:fastcheck, :sales, :payment, :verification_started]
[:fastcheck, :sales, :payment, :verified]
[:fastcheck, :sales, :payment, :mismatch]
[:fastcheck, :sales, :payment, :verification_failed]
[:fastcheck, :sales, :payment, :verification_idempotent]
```

Telemetry metadata must not include raw payload, raw verify response, phone, email, access_code, authorization_url, secret key, or plaintext tokens.

---

## 15. Security and PII Rules

```text
Provider secret key is read only through Paystack config boundary.
Secret key must never be logged or persisted.
authorization_url and access_code must never be logged.
raw_verify_response must be restricted to admin/system and redacted from operator/customer_session views.
Phone/email/customer fields from provider responses must be treated as PII.
Logs should include correlation_id, provider_reference hash/short form, payment_attempt_id, and event id where safe.
Do not expose provider payloads in user-facing responses.
Do not trust provider customer email/phone to select the order; use provider_reference and local PaymentAttempt ownership.
```

---

## 16. Human Review Checklist

Before accepting the agent output, manually verify:

```text
[ ] No Paystack HTTP call was added inside any Ash resource.
[ ] No verification call remains in the webhook controller.
[ ] No direct Repo status update bypasses named Ash actions.
[ ] No DB transaction wraps the outbound Paystack HTTP call.
[ ] PaymentAttempt verified_success requires status, amount, currency, and reference match.
[ ] Order paid_verified requires PaymentAttempt ownership and valid Order/CheckoutSession preconditions.
[ ] Expired checkout behavior does not issue tickets or consume inventory.
[ ] Duplicate worker execution is idempotent.
[ ] StateTransition rows are created for every state change.
[ ] Raw verify responses and PII are not visible to operator/customer_session.
[ ] Logs do not contain raw payloads, secrets, access_code, authorization_url, PII, or tokens.
[ ] No TicketIssue, Attendee, scanner sync, DeliveryAttempt, WhatsApp, refund, or Redis inventory mutation was added.
[ ] Tests include success, failure, idempotency, policy, redaction, and boundary creep cases.
```

---

## 17. TOON Coding-Agent Prompt

| Field | Content |
|---|---|
| Task | Implement VS-07B Paystack Transaction Verification as a verification-only payments slice. |
| Objective | Prove Paystack payments through backend server-side verification before FastCheck delivers value, while keeping failure/mismatch downstream handling for VS-07C and preventing ticket/scanner/inventory side effects. |
| Output | Update or create `lib/fastcheck/payments/paystack/transaction_verifier.ex`, `lib/fastcheck/payments/paystack/payment_verification.ex`, `lib/fastcheck/workers/verify_payment_worker.ex`, and required Ash action/test files following existing repo conventions. Add RED/GREEN tests under `test/fastcheck/payments/paystack/*` and `test/fastcheck/workers/*`. Final report must list touched files, tests, state actions, and VS-07C handoff cases. |
| Note | Use the existing VS-06A Paystack boundary; do not place Paystack HTTP in Ash resources. Do not hold DB transactions open during HTTP. Verify by provider_reference and require provider status success, amount match, currency match, reference match, and local PaymentAttempt ownership before `verified_success`/`paid_verified`. Use named Ash actions only; append StateTransition for every state change. Required indexes: `payment_attempts(provider, provider_reference)` unique, `payment_attempts(sales_order_id,status)`, `payment_events(provider_reference)`, `orders(event_id,status,inserted_at)`, `checkout_sessions(sales_order_id,status)`, `state_transitions(entity_type,entity_id,inserted_at)`. Caching: no inventory cache changes; invalidate admin/order dashboard cache only on `paid_verified` if existing. TTL/Redis: no inventory keys; Oban uniqueness by `payment_attempt_id` or `provider_reference`; optional verification dedupe key `sales:payments:paystack:verify:{provider_reference}` TTL 1–24h only if repo already uses Redis dedupe. PubSub: internal admin/status broadcast only, no customer ticket broadcast. Redaction: never log secret key, raw payload, raw verify response, access_code, authorization_url, phone, email, or tokens. Forbidden: webhook verification changes beyond worker integration, ticket issuance, Attendee mutation, scanner/mobile sync, DeliveryAttempt, WhatsApp/Meta behavior, refund/revocation, Redis inventory consume/release/reserve/re-reserve. |

---

## 18. Copy-Paste Prompt for Coding Agent

```text
You are implementing FastCheck Sales VS-07B — Paystack Transaction Verification.

Goal:
Implement server-side Paystack verification for existing PaymentAttempt records. This slice verifies provider status, amount, currency, and reference, then applies safe payment state transitions. It must not issue tickets, mutate Attendees, mutate scanner-visible state, or mutate Redis inventory.

Context:
- Ash domain: FastCheck.Sales
- Plain provider boundary: FastCheck.Payments.Paystack.TransactionVerifier
- Worker: FastCheck.Workers.VerifyPaymentWorker
- Resources allowed to mutate: PaymentAttempt, PaymentEvent, Order, CheckoutSession, StateTransition
- Resources forbidden from mutation: OrderLine, TicketOffer, TicketIssue, DeliveryAttempt, Conversation, existing Attendees/scanner/mobile-sync systems

Implementation rules:
1. Inspect existing conventions before changing files.
2. Call Paystack Verify Transaction only from plain module/worker code, never inside Ash resources.
3. Do not hold a DB transaction while the HTTP call is running.
4. Use Oban uniqueness by payment_attempt_id or provider_reference.
5. Load PaymentAttempt by provider + provider_reference and verify local ownership before any paid state transition.
6. Only mark PaymentAttempt verified_success when Paystack data.status is success and provider reference, amount, and currency match local values.
7. Only mark Order paid_verified when PaymentAttempt is verified_success and Order/CheckoutSession preconditions are valid.
8. Do not consume, release, reserve, or re-reserve inventory in Redis.
9. If checkout is expired/released or payment is late, classify safely and leave final outcome for VS-07C. Do not issue tickets.
10. Append StateTransition for every state change.
11. Store raw_verify_response only in sanitized/restricted form according to VS-00B.
12. Add RED/GREEN tests for success, failed provider status, amount mismatch, currency mismatch, reference mismatch, unmatched attempt, expired checkout, duplicate worker idempotency, provider timeout retry, policy restrictions, log redaction, and boundary creep.

Forbidden:
- Paystack HTTP from Ash resources
- Verification in webhook controller
- Direct Repo status updates
- Payment verified from webhook payload only
- TicketIssue creation
- Attendee mutation
- scanner/mobile sync mutation
- DeliveryAttempt creation
- WhatsApp/Meta behavior
- refund/revocation behavior
- Redis inventory mutation
- raw payload/secrets/PII/token logging

Final report:
List files changed, tests added, commands run, state transitions added, indexes verified, and all VS-07C handoff cases that remain unresolved.
```

---

## 19. Success Looks Like

```text
A valid paid Paystack transaction becomes a verified local PaymentAttempt and, when active checkout preconditions are valid, a paid_verified Order.
Invalid/mismatched/unmatched/expired cases are safe and cannot deliver value.
Duplicate verification is harmless.
Provider/network failure is retry-safe.
No customer, ticket, attendee, scanner, inventory, or WhatsApp side effect can occur in this slice.
The next agent can implement VS-07C using clear mismatch/late/unmatched classifications.
```

---

## 20. Next Slice

```text
VS-07C — Payment Failure and Mismatch Handling
```
