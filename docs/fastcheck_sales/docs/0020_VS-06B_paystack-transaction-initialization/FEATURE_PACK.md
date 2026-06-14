# FastCheck Sales Feature Planning Pack — VS-06B Paystack Transaction Initialization

**Pack ID:** `0020_VS-06B_paystack-transaction-initialization`  
**Slice:** `VS-06B`  
**Slice name:** Paystack Transaction Initialization  
**Version:** `v1.0`  
**Date:** 2026-06-13  
**Repository path:** `docs/fastcheck_sales/feature_packs/0020_VS-06B_paystack-transaction-initialization/`  
**Status:** Implementation planning pack — Sales/payment integration allowed, webhook/verification/ticket issuance forbidden  
**Primary area:** Payments / Checkout / Sales / Ash Actions / Security / Tests  
**Depends on:** VS-05, VS-06A, VS-00A, VS-00B, VS-01C, VS-01F, VS-21A  
**Blocks:** VS-06C, VS-07A, VS-07B, VS-07C, VS-19  
**Source docs:**

```text
docs/fastcheck_sales/SOURCE_DOCS/FastCheck_Sales_Ash_Atlas_Planning_Pack_v0.2.3_HARDENED.md
docs/fastcheck_sales/SOURCE_DOCS/FastCheck_Sales_Vertical_Slice_Roadmap_v1.1.3_HARDENED.md
```

---

## 1. Purpose

This pack instructs a coding agent to implement **backend Paystack transaction initialization** for a valid FastCheck Sales checkout/order.

VS-06A created the plain Paystack provider boundary. VS-06B connects that boundary to the durable Sales model in a controlled way:

```text
valid Sales order + active checkout session
  -> build provider-safe Paystack params from durable backend data
  -> call FastCheck.Payments.Paystack.TransactionInitializer
  -> persist a PaymentAttempt
  -> return a safe authorization URL result to the approved channel adapter
  -> do not verify payment yet
  -> do not issue tickets yet
```

Critical principle:

```text
Paystack initialization creates a payment attempt and payment link.
It is not proof of payment.
It must not mark an order paid.
It must not consume inventory.
It must not issue a ticket.
```

---

## 2. Ultimate Outcome

After VS-06B is complete:

```text
A valid active checkout/order can initialize a Paystack transaction from backend-owned data.
PaymentAttempt records are created idempotently with provider = paystack.
Provider references are backend-generated and unique.
Order/CheckoutSession payment-link state changes follow approved transition rules.
Repeated initialization requests for the same checkout/order return the existing active attempt instead of creating duplicate provider transactions.
Provider failures do not mark orders paid and do not lose inventory holds.
Authorization URLs and access codes are stored/restricted according to VS-00B policy and never logged.
No webhook ingestion exists yet.
No transaction verification exists yet.
No payment success is trusted yet.
No tickets are issued.
```

This slice activates **payment link creation**, not payment confirmation.

---

## 3. Scope

### In scope

```text
Create a Sales payment initialization service/orchestrator.
Validate Sales.Order state before initializing Paystack.
Validate CheckoutSession state and expiry before initializing Paystack.
Build Paystack initialize params from durable backend data only.
Generate backend-owned provider_reference and idempotency_key.
Call VS-06A TransactionInitializer provider boundary.
Create PaymentAttempt using approved Ash actions.
Store provider_reference, authorization_url, access_code, amount, currency, initialized_at, and restricted raw_initialize_response if policy allows.
Return a safe payment-link result to the caller.
Add idempotency guard against duplicate initialization.
Add short lock/advisory lock/Redis lock if the project pattern supports it, but do not mutate inventory reservation keys directly.
Add state transition/audit behavior required by the approved matrix.
Add RED/GREEN tests for valid initialization, invalid states, duplicate calls, provider failures, expiry, and log redaction.
```

### Out of scope

```text
No Paystack webhook controller.
No Paystack webhook route.
No PaymentEvent persistence.
No server-side transaction verification workflow.
No marking PaymentAttempt verified_success.
No marking Order paid_verified or paid_unverified.
No payment-after-expiry fulfillment decision.
No ticket issuance.
No Attendee creation.
No DeliveryAttempt creation.
No WhatsApp message sending.
No Meta API behavior.
No scanner changes.
No Redis inventory reserve/consume/release implementation.
No consuming inventory on Paystack initialization.
No refund/revocation behavior.
No admin manual review UI.
```

---

## 4. Required Pre-Implementation Discovery

Before editing code, the agent must inspect the existing repository and document findings in its final report:

```text
Existing VS-05 checkout service/orchestrator name and API.
Existing Order and CheckoutSession states/actions from VS-05.
Existing PaymentAttempt and PaymentEvent Ash resource structure from VS-01C.
Existing Ash action style and transaction conventions.
Existing actor/policy helper conventions from VS-01F.
Existing StateTransition audit helper from VS-00A/VS-05 if already implemented.
Existing correlation_id/request_id conventions from VS-21A.
Existing Paystack modules from VS-06A.
Existing route/url helper conventions for callback_url construction.
Existing feature-flag or runtime config style.
Existing test mocking style for Paystack boundary calls.
```

Do not invent duplicate orchestration modules if VS-05 already created an approved checkout/payment namespace.

---

## 5. Domain and Boundary Details

### Ash domain

```text
FastCheck.Sales
```

### Ash resources modified or used

```text
FastCheck.Sales.Order
FastCheck.Sales.CheckoutSession
FastCheck.Sales.PaymentAttempt
FastCheck.Sales.StateTransition
```

### Ash resources referenced only

```text
FastCheck.Sales.OrderLine
FastCheck.Sales.TicketOffer
FastCheck.Sales.PaymentEvent
```

### Plain Elixir modules used from VS-06A

```text
FastCheck.Payments.Paystack.TransactionInitializer
FastCheck.Payments.Paystack.ResponseSanitizer
FastCheck.Payments.Paystack.Error
```

### Preferred Sales orchestration module

Use the existing VS-05 namespace if it exists. Otherwise prefer one of:

```text
lib/fastcheck/sales/payments/transaction_initialization.ex
lib/fastcheck/sales/payments/paystack_initialization.ex
lib/fastcheck/sales/payment_initialization.ex
```

Recommended module name if no convention exists:

```text
FastCheck.Sales.Payments.TransactionInitialization
```

### Possible files to update

```text
lib/fastcheck/sales/payment_attempt.ex
lib/fastcheck/sales/order.ex
lib/fastcheck/sales/checkout_session.ex
lib/fastcheck/sales/state_transition.ex
lib/fastcheck/sales/payments/transaction_initialization.ex
```

### Preferred test files

```text
test/fastcheck/sales/payments/transaction_initialization_test.exs
test/fastcheck/sales/payment_attempt_initialization_actions_test.exs
test/fastcheck/sales/payments/paystack_initialization_idempotency_test.exs
test/fastcheck/sales/payments/paystack_initialization_security_test.exs
```

---

## 6. Required Business Preconditions

Paystack initialization may proceed only when all required conditions are true.

### Order preconditions

```text
Order exists.
Order belongs to the selected event/organization scope if tenanting is active.
Order status is awaiting_payment or another explicitly approved pre-payment state from VS-00A/VS-05.
Order is not cancelled.
Order is not expired.
Order is not refunded.
Order is not ticket_issued.
Order total_amount_cents is greater than 0.
Order currency is supported and matches the associated OrderLines.
Order has at least one OrderLine.
OrderLine totals sum to Order.total_amount_cents.
```

### CheckoutSession preconditions

```text
CheckoutSession exists for the order.
CheckoutSession status is hold_attached or payment_link_sent for idempotent repeat.
CheckoutSession has not expired.
CheckoutSession has a redis_hold_key or approved durable hold reference from VS-05.
CheckoutSession hold_quantity matches the order line quantity total where applicable.
```

### Buyer/contact preconditions

```text
Paystack requires a customer email for transaction initialization.
Do not invent fake customer email behavior in this slice.
If buyer_email is missing and no approved fallback policy exists, return a safe :missing_buyer_email error and do not call Paystack.
If a later WhatsApp flow wants phone-only checkout, that must be handled through an explicit approved policy before VS-19, not guessed here.
```

### Provider preconditions

```text
Paystack config from VS-06A is valid.
Provider reference is backend-generated.
Amount and currency are derived from Sales.Order, never client input.
Callback URL is server-generated from approved config/route helpers.
Metadata is minimal and non-sensitive.
```

---

## 7. Recommended API Contract

### Public service function

```text
initialize_for_checkout(order_id_or_public_reference, actor, opts \\ [])
```

or if VS-05 uses checkout session IDs:

```text
initialize_for_checkout_session(checkout_session_id, actor, opts \\ [])
```

### Inputs

```text
order identifier or checkout session identifier
actor
correlation_id
request_id
source_channel
callback_url override only if trusted/internal
idempotency_key override only if trusted/internal
```

### Outputs

Recommended success shape:

```text
{:ok,
 %{
   payment_attempt_id: id,
   provider: :paystack,
   provider_reference: safe_reference,
   authorization_url: authorization_url,
   status: :initialized,
   idempotent?: boolean
 }}
```

Recommended error shape:

```text
{:error,
 %{
   type: atom,
   safe_message: binary,
   retryable?: boolean,
   safe_metadata: map
 }}
```

Do not return:

```text
access_code unless the approved caller explicitly needs it.
raw_initialize_response.
secret keys.
Authorization headers.
full customer email/phone in error metadata.
```

---

## 8. Provider Reference and Idempotency Contract

### Provider reference

Provider reference must be generated by the backend.

Recommended shape:

```text
FC-{order_public_reference}-{attempt_sequence_or_short_random_suffix}
```

Rules:

```text
Must be unique per provider.
Must not expose sequential DB IDs.
Must be safe to share with Paystack.
Must be persisted on PaymentAttempt.
Must be used later by webhook and verification slices.
```

### Idempotency key

Recommended idempotency key source:

```text
paystack:init:{sales_order_id}:{checkout_session_id}
```

or equivalent opaque hash.

Rules:

```text
Repeated calls for the same order/checkout should return the existing initialized active attempt.
Duplicate concurrent calls must not create multiple active Paystack attempts.
If a previous attempt failed before provider_reference was persisted, retry may create a new attempt only according to an explicit retry policy.
If a previous attempt has an authorization_url and is still valid, return it rather than calling Paystack again.
If the order changed amount/currency after an attempt exists, block and move to manual_review or require a new checkout according to VS-00A policy.
```

### Locking recommendation

Use the project-approved short lock strategy:

```text
DB advisory lock by order id/public reference
or Redis SETNX lock outside inventory reservation keys
or Ash/Ecto uniqueness + transaction pattern
```

Rules:

```text
Do not hold a database transaction open during the external Paystack HTTP call.
Do not mutate Redis inventory keys directly.
Use a bounded lock TTL if Redis lock is used.
Always re-check existing PaymentAttempt after acquiring the lock.
```

---

## 9. State Transition Contract

This slice may add or use only these payment-initialization transitions.

### PaymentAttempt

Allowed:

```text
create_initialized
mark_authorization_url_sent only when the approved channel actually presents/sends the URL
mark_failed for initialization failure if a PaymentAttempt record was created
mark_manual_review for ambiguous state
```

Forbidden:

```text
mark_webhook_received
mark_verification_started
mark_verified_success
mark_amount_mismatch
mark_currency_mismatch
mark_duplicate unless duplicate attempt is represented by policy
mark_refunded
```

### Order

Allowed only if already defined by VS-05/VS-00A:

```text
mark_awaiting_payment
mark_payment_pending only if policy says initialized link means payment is pending
mark_manual_review for ambiguous initialization state
```

Forbidden:

```text
mark_paid_unverified
mark_paid_verified
queue_fulfillment
mark_ticket_issued
mark_partially_issued
mark_refunded
```

### CheckoutSession

Allowed:

```text
mark_payment_link_sent only when the URL has actually been returned/presented/sent by the approved entrypoint
mark_manual_review if available and policy requires it
```

Forbidden:

```text
expire_session unless VS-05/VS-14 owns expiry
release_session unless VS-05/VS-14 owns release behavior
paid state transition unless verification/payment workflow owns it
```

### StateTransition audit

Every status change must append a `StateTransition` with:

```text
entity_type
entity_id
from_state
to_state
actor_type
actor_id when available
reason
correlation_id
idempotency_key
source
safe metadata only
```

---

## 10. Paystack Initialize Params Contract

Build params from trusted backend state only.

### Required provider params

```text
amount: Order.total_amount_cents
currency: Order.currency
email: Order.buyer_email
reference: backend-generated provider_reference
callback_url: server-generated callback URL
metadata: minimal safe metadata
```

### Allowed metadata

```text
order_public_reference
event_id if safe
source_channel
correlation_id
checkout_session_id or public checkout reference if safe
```

### Forbidden metadata

```text
buyer_phone unless explicitly required and approved
full buyer_name unless explicitly required and approved
raw internal DB IDs if public exposure is not approved
secret keys
access_code
authorization_url
large state_data blobs
raw Redis keys unless explicitly approved
```

### Amount/currency rules

```text
Never accept amount from client params.
Never accept currency from client params.
Never recalculate price from current TicketOffer during payment initialization.
Use durable Order/OrderLine price snapshots from VS-05.
```

---

## 11. Security and PII Rules

### Never log

```text
PAYSTACK_SECRET_KEY
Authorization header
access_code
authorization_url
raw_initialize_response
buyer_email
buyer_phone
full provider response body
full provider_reference if policy requires partial redaction
```

### Safe logs

```text
operation: paystack_initialize
provider: paystack
order_public_reference
payment_attempt_id
http_status
error_type
retryable?
correlation_id
duration_ms
```

### Raw response storage

```text
raw_initialize_response may be stored only in the restricted PaymentAttempt field defined by VS-00B/VS-01C.
Admin/operator list views must not expose raw_initialize_response.
Errors and final reports must not print raw provider payloads.
```

### Customer-facing return

The service may return `authorization_url` to an approved caller so the customer can be redirected or sent the link.

Rules:

```text
Do not log the URL.
Do not expose access_code unless strictly required by the approved caller.
Do not expose raw provider response.
Do not expose internal DB IDs as public references.
```

---

## 12. Performance and Scaling Rules

```text
No Paystack HTTP call inside an Ash resource action.
No Paystack HTTP call inside a long database transaction.
No Redis inventory mutation in this slice.
No inventory consume on initialization.
Use short provider timeouts inherited from VS-06A.
Use idempotency/locking to prevent duplicate provider transactions under double-click/retry/concurrent requests.
Return provider_unavailable/timeout safely and let the caller retry or manual-review according to policy.
Do not perform dashboard/list queries in this slice.
Do not load large StateTransition or PaymentEvent histories to initialize a payment.
```

Target behavior:

```text
Sub-second local validation before provider call.
Bounded provider wait time.
No unbounded retries.
No duplicate provider attempts under normal double-submit.
No DB lock held while waiting on Paystack.
```

---

## 13. RED/GREEN Test Plan

Tests must be written RED first where behavior does not exist, then made GREEN by the minimal implementation.

### 13.1 Valid initialization tests

#### RED

```text
Test fails because initialize_for_checkout does not exist.
Test fails because a valid awaiting_payment order cannot create a PaymentAttempt.
Test fails because Paystack TransactionInitializer is not called with backend-derived amount/currency/reference/email.
Test fails because CheckoutSession is not updated according to the approved payment-link policy.
```

#### GREEN

```text
Valid active checkout initializes Paystack.
PaymentAttempt is created with provider paystack, provider_reference, amount, currency, initialized_at, authorization_url, access_code, and restricted raw response if policy allows.
Returned result contains a safe authorization_url result for the caller.
StateTransition rows are appended for any state changes.
```

### 13.2 Invalid order/checkout state tests

#### RED

```text
Cancelled order still initializes Paystack.
Expired order still initializes Paystack.
Refunded order still initializes Paystack.
Ticket-issued order still initializes Paystack.
CheckoutSession expired but Paystack is still called.
CheckoutSession missing active hold but Paystack is still called.
Order total is zero or negative but Paystack is still called.
OrderLine totals do not match Order total but Paystack is still called.
```

#### GREEN

```text
Invalid states return safe errors and do not call Paystack.
No PaymentAttempt is created for invalid state.
No order is marked paid.
No inventory is consumed or released.
Manual-review transition occurs only where policy explicitly requires it.
```

### 13.3 Missing buyer email tests

#### RED

```text
Order with missing buyer_email calls Paystack anyway.
Implementation invents a fake customer email without approved policy.
Missing email error logs phone/name/raw state_data.
```

#### GREEN

```text
Missing buyer_email returns safe :missing_buyer_email error.
No Paystack request is made.
No PaymentAttempt is created unless policy explicitly says to record a failed attempt.
Logs do not expose phone/name/raw state_data.
```

### 13.4 Idempotency and concurrency tests

#### RED

```text
Double-click creates two PaymentAttempts.
Concurrent calls call Paystack twice.
Repeated call creates a new provider_reference instead of returning existing active attempt.
Existing active PaymentAttempt is ignored.
```

#### GREEN

```text
Repeated initialization for the same active checkout returns the existing PaymentAttempt/link.
Concurrent calls create at most one active PaymentAttempt for the order/checkout.
Provider call is not duplicated under normal double-submit.
Unique indexes/idempotency keys protect against duplicate rows.
```

### 13.5 Provider failure tests

#### RED

```text
Paystack timeout raises raw exception.
Provider 401/500 response is stored/logged unsafely.
Provider failure marks order paid or payment_pending incorrectly.
Provider failure consumes or releases inventory.
```

#### GREEN

```text
Provider failures return normalized safe errors.
No order paid state is set.
No ticket is issued.
No inventory is consumed.
Failed/ambiguous attempts are recorded only according to policy.
Logs remain redacted.
```

### 13.6 Policy/actor tests

#### RED

```text
Unauthenticated customer_session can initialize arbitrary order payment.
Operator can initialize payment for unrelated event/organization.
Customer can spoof source_channel, amount, currency, provider_reference, or callback_url.
```

#### GREEN

```text
Actor checks enforce customer/order ownership or secure checkout-token ownership.
Admin/operator access is event/organization scoped when tenanting is active.
Amount, currency, provider_reference, source_channel, and callback_url are backend-controlled.
```

### 13.7 Boundary tests

#### RED

```text
Ash resource action calls FastCheck.Payments.Paystack.TransactionInitializer directly.
Webhook controller/route appears in this slice.
PaymentEvent persistence is added.
Transaction verification is added.
Ticket issuance or Attendee creation is triggered.
WhatsApp message sending is added.
Redis inventory consume/release is called during initialization.
```

#### GREEN

```text
Only the approved Sales payment initialization service calls the Paystack provider boundary.
No webhook controller/worker is added.
No PaymentEvent is persisted.
No verification, ticketing, Attendee, scanner, WhatsApp, or Redis inventory behavior is introduced.
```

### 13.8 Log redaction tests

#### RED

```text
Captured logs contain authorization_url.
Captured logs contain access_code.
Captured logs contain raw_initialize_response.
Captured logs contain buyer_email or buyer_phone.
Captured logs contain Authorization header or PAYSTACK_SECRET_KEY.
```

#### GREEN

```text
Captured logs redact authorization_url, access_code, raw provider payloads, email, phone, Authorization header, and secret key.
Errors are safe to inspect.
Final agent report does not print sensitive values.
```

---

## 14. Acceptance Criteria

A reviewer may mark this pack complete only when:

```text
A backend Sales payment initialization service exists.
The service validates Order and CheckoutSession state before calling Paystack.
The service builds provider params only from durable backend data.
The service calls VS-06A Paystack TransactionInitializer.
PaymentAttempt is created idempotently with provider paystack and backend-generated provider_reference.
Duplicate initialization returns the existing active attempt/link rather than creating duplicates.
Invalid/expired/cancelled/refunded/ticket_issued states do not call Paystack.
Missing buyer_email is handled explicitly and safely.
Provider failures are normalized and do not mark orders paid.
No inventory consume/release happens in this slice.
No webhook route/controller/worker is added.
No PaymentEvent persistence is added.
No verification workflow is added.
No tickets are issued.
No Attendees/scanner/WhatsApp/DeliveryAttempt behavior is added.
StateTransition audit is appended for all state changes.
Authorization URL and access code are never logged.
RED/GREEN tests exist and pass.
Existing Sales checkout, Paystack boundary, and scanner tests still pass.
Final report lists discovered conventions, files changed, tests run, and explicit boundary confirmation.
```

---

## 15. Files to Create or Update

Allowed likely files:

```text
lib/fastcheck/sales/payments/transaction_initialization.ex
lib/fastcheck/sales/payment_attempt.ex
lib/fastcheck/sales/order.ex
lib/fastcheck/sales/checkout_session.ex
lib/fastcheck/sales/state_transition.ex
test/fastcheck/sales/payments/transaction_initialization_test.exs
test/fastcheck/sales/payment_attempt_initialization_actions_test.exs
test/fastcheck/sales/payments/paystack_initialization_idempotency_test.exs
test/fastcheck/sales/payments/paystack_initialization_security_test.exs
```

Allowed to read or call, but avoid modifying unless necessary:

```text
lib/fastcheck/payments/paystack/transaction_initializer.ex
lib/fastcheck/payments/paystack/client.ex
lib/fastcheck/payments/paystack/response_sanitizer.ex
lib/fastcheck/sales/checkout.ex
```

Forbidden files/areas unless only reading for context:

```text
lib/fastcheck_web/controllers/webhooks/paystack_controller.ex
lib/fastcheck/workers/paystack_webhook_worker.ex
lib/fastcheck/workers/verify_payment_worker.ex
lib/fastcheck/tickets/issuer.ex
lib/fastcheck/attendees/**
lib/fastcheck/mobile/**
lib/fastcheck/messaging/whatsapp/**
lib/fastcheck/sales/inventory/reservation_ledger.ex
lib/fastcheck/sales/inventory/redis_scripts.ex
```

If the repository already has a payment initialization service, update the existing approved module instead of duplicating it.

---

## 16. TOON Coding-Agent Prompt

| Field | Content |
|---|---|
| Task | Implement VS-06B Paystack Transaction Initialization for valid FastCheck Sales checkouts. |
| Objective | Connect the VS-05 Sales checkout/order core to the VS-06A Paystack provider boundary so the backend can create idempotent Paystack payment attempts and return safe authorization URLs without verifying payment, issuing tickets, or consuming inventory. |
| Output | Add/update a Sales payment initialization service such as `lib/fastcheck/sales/payments/transaction_initialization.ex`, add necessary named Ash actions on `PaymentAttempt`, `Order`, `CheckoutSession`, and `StateTransition`, and add RED/GREEN tests under `test/fastcheck/sales/payments/`. |
| Note | Use Ash 3.x patterns and existing project conventions. Validate order and checkout state before provider calls. Build amount/currency/reference/email/callback_url from backend durable data only. Use backend-generated `provider_reference` and idempotency key. Do not call Paystack inside Ash resource actions or DB transactions. Do not verify payment, persist PaymentEvent, add webhook controller/worker, mark order paid, consume/release inventory, issue tickets, create Attendees, send WhatsApp, or touch scanner paths. Do not invent fake email behavior; return safe `:missing_buyer_email` if no approved policy exists. Redact authorization_url, access_code, raw_initialize_response, email, phone, Authorization header, and secrets from logs. Write RED tests first, then minimal GREEN implementation. |

---

## 17. Copy-Paste Prompt for Coding Agent

```text
You are implementing FastCheck Sales feature slice VS-06B — Paystack Transaction Initialization.

Context:
- VS-06A created the plain Paystack provider boundary.
- VS-05 created the Sales order/checkout core and Redis hold integration.
- This slice connects a valid active Sales checkout/order to Paystack transaction initialization.
- Paystack initialization is not payment verification and must not deliver ticket value.

Your task:
1. Inspect the repo for existing VS-05 checkout service, Ash action patterns, policy helpers, StateTransition helpers, Paystack modules from VS-06A, and test conventions.
2. Create or update an approved Sales payment initialization service, preferably `FastCheck.Sales.Payments.TransactionInitialization` unless the repo has a better existing namespace.
3. Validate Order and CheckoutSession state before any provider call:
   - order exists, active, unpaid, unexpired, not cancelled/refunded/ticket_issued
   - checkout session exists, active, unexpired, and has an approved hold reference
   - order has valid amount/currency/order lines
   - buyer_email exists unless an approved no-email Paystack policy exists
4. Generate backend-owned `provider_reference` and idempotency key.
5. Build Paystack initialize params from durable backend data only: amount, currency, buyer_email, reference, callback_url, and minimal safe metadata.
6. Call `FastCheck.Payments.Paystack.TransactionInitializer` from VS-06A through the service layer only.
7. Create a `PaymentAttempt` with provider `paystack`, provider_reference, amount, currency, initialized_at, authorization_url, access_code, idempotency_key, and restricted raw_initialize_response only if allowed by policy.
8. Add state transitions/audit rows for any Order, CheckoutSession, or PaymentAttempt status change.
9. Make repeated initialization idempotent: return the existing active attempt/link rather than creating duplicate Paystack attempts.
10. Add RED/GREEN tests for valid initialization, invalid states, missing buyer email, duplicate calls, provider failures, actor/policy restrictions, boundary creep, and log redaction.

Forbidden:
- No Paystack HTTP calls inside Ash resource actions.
- No DB transaction held open during Paystack HTTP call.
- No Paystack webhook controller/route/worker.
- No PaymentEvent persistence.
- No transaction verification.
- No mark_paid_unverified or mark_paid_verified.
- No ticket issuance.
- No Attendee/scanner changes.
- No WhatsApp/Meta behavior.
- No Redis inventory consume/release.
- No fake customer email unless an approved policy already exists.
- No logging of authorization_url, access_code, raw_initialize_response, buyer_email, buyer_phone, Authorization header, or secret keys.

Keep the implementation minimal, state-safe, and idempotent. Final report must list files changed, tests run, project conventions discovered, and explicit confirmation that this slice only initializes Paystack transactions and does not verify payment or issue tickets.
```

---

## 18. Human Review Checklist

Before accepting the implementation, verify:

```text
Payment initialization service exists under approved namespace.
Service validates Order and CheckoutSession state before Paystack call.
Service derives amount/currency/reference/email from backend data only.
Provider reference is backend-generated and unique.
Duplicate initialization is idempotent.
No DB transaction is held open across Paystack HTTP call.
PaymentAttempt is created with correct provider/status/amount/currency/reference fields.
StateTransition audit exists for all state changes.
Invalid/expired/cancelled/refunded/ticket_issued states do not call Paystack.
Missing buyer_email is handled explicitly.
Provider failures do not mark orders paid or consume inventory.
No webhook controller/route/worker was added.
No PaymentEvent persistence was added.
No verification workflow was added.
No ticket issuance, Attendee mutation, scanner behavior, Redis inventory mutation, or WhatsApp behavior was added.
Logs and errors redact authorization_url, access_code, raw payloads, email, phone, Authorization header, and secrets.
RED/GREEN tests cover success, failure, idempotency, policy, boundary, and redaction paths.
Existing checkout, Paystack boundary, Sales, and scanner tests still pass.
```

---

## 19. Next Slice

```text
VS-06C — Paystack Initialization Tests
```

VS-06C will harden the initialization path with focused idempotency, config, provider-failure, and no-secret-logging tests. VS-06B should already include RED/GREEN tests, but VS-06C is the dedicated QA hardening slice before webhook ingestion starts.
