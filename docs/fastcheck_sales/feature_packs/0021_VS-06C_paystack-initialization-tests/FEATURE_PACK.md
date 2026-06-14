# FastCheck Sales Feature Planning Pack — VS-06C Paystack Initialization Tests

**Pack ID:** `0021_VS-06C_paystack-initialization-tests`  
**Slice:** `VS-06C`  
**Slice name:** Paystack Initialization Tests  
**Version:** `v1.0`  
**Date:** 2026-06-13  
**Repository path:** `docs/fastcheck_sales/feature_packs/0021_VS-06C_paystack-initialization-tests/`  
**Status:** Test-hardening planning pack — test implementation allowed, production behavior changes only to satisfy VS-06B contracts  
**Primary area:** Payments / QA / Security / Idempotency / Boundary Tests  
**Depends on:** VS-06B, VS-06A, VS-05, VS-00A, VS-00B, VS-01C, VS-01F, VS-21A  
**Blocks:** VS-07A, VS-07B, VS-07C, VS-19  
**Source docs:**

```text
docs/fastcheck_sales/SOURCE_DOCS/FastCheck_Sales_Ash_Atlas_Planning_Pack_v0.2.3_HARDENED.md
docs/fastcheck_sales/SOURCE_DOCS/FastCheck_Sales_Vertical_Slice_Roadmap_v1.1.3_HARDENED.md
```

---

## 1. Purpose

This pack instructs a coding agent to harden **Paystack transaction initialization tests** after VS-06B.

VS-06B introduced backend Paystack transaction initialization for a valid Sales checkout/order. VS-06C proves that behavior is safe under realistic retries, invalid states, provider failures, misconfiguration, logging risks, and boundary creep.

Critical principle:

```text
Initialization creates or returns a payment attempt/link.
Initialization is not payment verification.
Initialization must not issue tickets, consume inventory, mutate scanner state, or trust a webhook.
```

This is primarily a **RED/GREEN test slice**. It may patch VS-06B implementation only where tests expose contract violations. It must not add new payment lifecycle features.

---

## 2. Ultimate Outcome

After VS-06C is complete:

```text
Paystack initialization behavior is covered by focused success, failure, idempotency, config, and security tests.
Invalid order/checkout states cannot call Paystack.
Repeated or concurrent initialization cannot create duplicate active PaymentAttempts.
Provider failures are normalized and never mark orders paid.
Missing/invalid Paystack configuration is detected safely.
Authorization URLs, access codes, provider payloads, customer PII, and secrets are not logged.
Boundary tests prove no webhook, verification, ticketing, scanner, WhatsApp, or inventory-consume behavior leaked into initialization.
```

This slice makes VS-06B trustworthy enough for VS-07A webhook ingestion to begin.

---

## 3. Scope

### In scope

```text
Add tests for valid Paystack initialization through the approved Sales initialization service.
Add tests for order and checkout preconditions.
Add tests for buyer_email requirement or approved fallback policy.
Add tests for amount/currency/reference being backend-derived only.
Add tests for idempotent duplicate initialization.
Add tests for concurrent duplicate initialization if the test harness supports it safely.
Add tests for provider timeout/error/invalid response handling.
Add tests for missing or invalid Paystack config.
Add tests for StateTransition audit on allowed state changes.
Add tests for actor/policy restrictions.
Add tests that logs and returned errors are redacted.
Add boundary tests proving no webhook, verification, PaymentEvent, ticket issuance, Attendee, scanner, WhatsApp, or Redis inventory mutation behavior was added.
Patch VS-06B code only when necessary to make the tests pass.
```

### Out of scope

```text
No new Paystack initialization feature beyond VS-06B.
No Paystack webhook controller, route, or worker.
No PaymentEvent persistence.
No transaction verification.
No mark_paid_unverified.
No mark_paid_verified.
No payment-after-expiry fulfillment decision.
No ticket issuance.
No Attendee creation.
No DeliveryAttempt creation.
No WhatsApp or Meta API behavior.
No scanner behavior changes.
No Redis inventory consume/release/reserve changes.
No refund or revocation behavior.
No admin manual review UI.
No production secrets in test fixtures, logs, snapshots, or docs.
```

---

## 4. Required Pre-Test Discovery

Before writing tests, the agent must inspect the existing repository and document findings in the final report:

```text
Actual VS-06B initialization service module and public function.
Actual VS-06A Paystack test/mock boundary pattern.
Actual Order/CheckoutSession factory helpers.
Actual PaymentAttempt factory/helpers and Ash actions.
Actual actor helper conventions for system/admin/operator/customer_session.
Actual StateTransition audit helper or assertion style.
Actual log-capture/redaction test helpers.
Actual config/runtime access pattern for Paystack settings.
Actual feature flag or adapter injection pattern for provider clients.
Actual async/concurrency test constraints in the project.
```

Do not invent new testing conventions if the repo already has a clear style.

---

## 5. Domain and Boundary Details

### Ash domain

```text
FastCheck.Sales
```

### Ash resources tested

```text
FastCheck.Sales.Order
FastCheck.Sales.OrderLine
FastCheck.Sales.CheckoutSession
FastCheck.Sales.PaymentAttempt
FastCheck.Sales.StateTransition
```

### Ash resources explicitly not used/created in this slice

```text
FastCheck.Sales.PaymentEvent
FastCheck.Sales.TicketIssue
FastCheck.Sales.DeliveryAttempt
FastCheck.Sales.Conversation
```

### Plain modules tested

Use the actual names from VS-06A/VS-06B. Expected names may include:

```text
FastCheck.Sales.Payments.TransactionInitialization
FastCheck.Payments.Paystack.TransactionInitializer
FastCheck.Payments.Paystack.Config
FastCheck.Payments.Paystack.Client
FastCheck.Payments.Paystack.ResponseSanitizer
FastCheck.Payments.Paystack.Error
```

### Preferred test files

Use the existing project naming convention. If no convention exists, prefer:

```text
test/fastcheck/sales/payments/paystack_initialization_test.exs
test/fastcheck/sales/payments/paystack_initialization_idempotency_test.exs
test/fastcheck/sales/payments/paystack_initialization_config_test.exs
test/fastcheck/sales/payments/paystack_initialization_security_test.exs
test/fastcheck/sales/payments/paystack_initialization_boundary_test.exs
```

### Possible production files to patch only if tests expose gaps

```text
lib/fastcheck/sales/payments/transaction_initialization.ex
lib/fastcheck/sales/payment_attempt.ex
lib/fastcheck/sales/order.ex
lib/fastcheck/sales/checkout_session.ex
lib/fastcheck/payments/paystack/config.ex
lib/fastcheck/payments/paystack/transaction_initializer.ex
lib/fastcheck/payments/paystack/response_sanitizer.ex
```

Do not create broad new architecture in this slice.

---

## 6. RED/GREEN Test Plan

Write the tests RED first. Then make the smallest safe implementation changes needed for GREEN.

### Group A — Valid initialization

RED tests must fail if:

```text
A valid active checkout/order cannot initialize a Paystack transaction.
The created PaymentAttempt does not use provider = paystack.
The PaymentAttempt does not persist provider_reference, amount_cents, currency, initialized_at, and safe status.
The result does not return a safe authorization_url to the caller.
OrderLine price snapshots are ignored and current TicketOffer price is used instead.
StateTransition audit is missing for state changes performed by initialization.
```

GREEN requires:

```text
Valid checkout/order initializes exactly one active PaymentAttempt.
Amount and currency come from durable Order/OrderLine state.
Provider reference is backend-generated and unique.
StateTransition rows exist for all allowed state changes.
Returned result excludes access_code and raw provider response unless explicitly approved.
```

---

### Group B — Invalid order/checkout states

RED tests must fail if Paystack is called for:

```text
cancelled order
expired order
refunded order
ticket_issued order
manual_review order unless explicitly allowed by transition policy
checkout session expired
checkout session released
checkout session missing Redis hold reference
checkout session belonging to a different order
order with no order lines
order with mismatched order total and line total
```

GREEN requires:

```text
Invalid states return safe errors.
Provider boundary is not called.
No PaymentAttempt is created.
No paid state is applied.
No inventory mutation occurs.
```

---

### Group C — Buyer email and phone-only risk

RED tests must fail if:

```text
buyer_email is missing and Paystack is still called without an approved fallback policy.
A fake placeholder email is generated silently.
Phone-only WhatsApp checkout policy is invented in this slice.
Customer phone/email leaks into unsafe error metadata or logs.
```

GREEN requires:

```text
Missing email returns a safe :missing_buyer_email or approved project-specific error.
No provider call is made when required provider params are missing.
Error metadata is safe and redacted.
Future WhatsApp phone-only behavior is left to an explicit later policy, not guessed here.
```

---

### Group D — Idempotency and duplicate submit safety

RED tests must fail if:

```text
Two repeated calls create two active PaymentAttempts for the same order/checkout.
Two repeated calls make two provider initialize calls when an active initialized attempt already exists.
The same idempotency key can create conflicting PaymentAttempts.
Provider reference uniqueness is not enforced by test coverage.
Duplicate call returns a different authorization_url when an active attempt exists.
```

GREEN requires:

```text
Duplicate initialization returns the existing active PaymentAttempt/link.
Provider initialize boundary is called once for repeated identical calls.
Unique indexes/identities protect provider_reference and idempotency_key behavior.
Concurrent double-submit is covered if the repo can support deterministic concurrency tests.
If concurrency test is unstable in this environment, include a deterministic lock/idempotency test and document the reason.
```

---

### Group E — Provider failure and timeout handling

RED tests must fail if:

```text
Provider timeout raises raw exception to caller.
Provider error marks Order paid, CheckoutSession paid, or PaymentAttempt verified_success.
Provider error logs raw response, Authorization header, secret key, access_code, authorization_url, email, or phone.
Ambiguous provider response creates a successful active attempt without required fields.
Failed initialization loses existing inventory holds or releases/consumes Redis inventory.
```

GREEN requires:

```text
Provider failures return normalized safe errors.
No paid/verified/ticketing state is applied.
Any failed PaymentAttempt state follows VS-06B policy.
Logs are redacted.
Inventory hold state is left to VS-05/VS-14 policy and not consumed/released by initialization.
```

---

### Group F — Config and secret safety

RED tests must fail if:

```text
Missing Paystack secret/config crashes with an unsafe exception.
Invalid base URL or callback URL creates an unsafe provider call.
Secret key, Authorization header, access_code, authorization_url, or raw provider body appears in logs.
Test fixtures contain real-looking production secrets.
Config errors are returned as broad internal stack traces.
```

GREEN requires:

```text
Missing/invalid config returns safe config error.
Provider boundary is not called when required config is invalid.
No test fixture contains real secrets.
Log-capture tests prove redaction.
```

---

### Group G — Policy and actor checks

RED tests must fail if:

```text
customer_session can broadly initialize payment without approved checkout-session scope.
operator can initialize payment outside allowed support/admin-assisted flow.
admin/system actor boundaries are ignored.
Actor/event/organization isolation is bypassed if tenanting exists.
Raw initialize response is visible to operator/customer_session.
```

GREEN requires:

```text
Only approved actors/flows can initialize payments.
customer_session behavior is controlled and scoped.
operator/admin behavior matches VS-01F policies.
Raw provider internals remain restricted.
```

---

### Group H — Boundary creep tests

RED tests must fail if this slice introduces or calls:

```text
Paystack webhook controller/route
Paystack webhook worker
PaymentEvent store/process action
server-side transaction verification
mark_webhook_received
mark_verification_started
mark_verified_success
mark_paid_unverified
mark_paid_verified
queue_fulfillment
IssueTicketsWorker
FastCheck.Tickets.Issuer
Attendee mutation
DeliveryAttempt creation
WhatsApp/Meta modules
scanner/mobile sync mutation
Redis inventory consume/release/reserve mutation from initialization
```

GREEN requires:

```text
Initialization remains payment-link creation only.
No ticket value is delivered.
No webhook/verification logic exists in this slice.
No scanner/inventory/WhatsApp behavior is added.
```

---

## 7. Acceptance Criteria

The slice is accepted only when all of these are true:

```text
All VS-06B initialization tests pass.
Invalid order/checkout state tests prove Paystack is not called.
Idempotency tests prove duplicate calls do not create duplicate active attempts.
Provider failure tests prove no paid/verified/ticketing/inventory mutation happens.
Config tests prove missing/invalid Paystack config is safe.
Security tests prove secrets, PII, authorization_url, access_code, raw provider responses, and headers are redacted.
Policy tests prove approved actor behavior and forbidden broad customer/operator access.
Boundary tests prove no webhook, verification, PaymentEvent processing, ticket issuance, scanner, WhatsApp, or inventory mutation was added.
No production secrets are committed.
No snapshots or fixtures contain sensitive values.
Final report lists any VS-06B contract gaps discovered and patched.
```

---

## 8. Performance & Scaling Review

### Data layer classification

```text
Hot data: none introduced here; initialization must not mutate inventory hot keys.
Warm data: none introduced here.
Cold data: PaymentAttempt, Order, CheckoutSession, and StateTransition records in Postgres.
Provider I/O: Paystack initialize call through VS-06A boundary only.
```

### Required index/identity coverage to verify in tests or review

```text
sales_payment_attempts unique(provider, provider_reference)
sales_payment_attempts index(sales_order_id, status)
sales_payment_attempts idempotency_key identity/index if implemented by VS-06B
sales_orders unique(public_reference)
sales_checkout_sessions unique(sales_order_id)
sales_state_transitions index(entity_type, entity_id, inserted_at)
```

### Concurrency and latency rules

```text
Do not hold DB transactions open during Paystack HTTP calls.
Do not perform dashboard-style broad reads in payment initialization.
Duplicate initialization must be blocked by idempotency/lock/unique constraints, not by caller trust.
Provider timeout must be bounded by VS-06A client config.
No excess Redis or Postgres calls beyond order/session/attempt lookup and write.
```

### Redis rules

```text
Redis inventory structures are not mutated in this slice.
If VS-06B uses a Redis SETNX-style short lock, test bounded TTL and release-on-error behavior.
Do not use sales:offer:* availability/holds keys from initialization tests except to assert they are untouched if helper support exists.
```

### Cache/PubSub rules

```text
No Cachex or Redis warm-cache invalidation is required for initialization tests.
No LiveView/PubSub broadcast is required unless VS-05/VS-06B already defined an order-payment-link notification; if present, test it without adding new behavior.
```

---

## 9. Security Review

### Sensitive values that must not appear in logs/errors

```text
PAYSTACK_SECRET_KEY
Authorization header
access_code
authorization_url
raw_initialize_response
buyer_email
buyer_phone
full buyer_name
provider raw response body
plaintext tokens
Redis hold token if considered sensitive by VS-00B
```

### Required safe-error behavior

```text
Return safe error atoms/classes.
Do not bubble provider stack traces to customers/operators.
Do not include raw Paystack error bodies in public/support-facing messages.
Use correlation_id/request_id for debugging instead of sensitive payload dumps.
```

---

## 10. Failure Modes to Cover

```text
Provider timeout.
Provider 4xx error.
Provider 5xx error.
Provider malformed success response without authorization_url.
Provider success response without reference/access_code if required by implementation.
Missing buyer_email.
Invalid callback_url config.
Missing secret key.
Duplicate browser/customer submit.
Duplicate admin-assisted submit.
Concurrent initialization race.
Order expires between first load and provider response.
Existing active attempt exists before new request.
Existing failed attempt exists and retry policy is unclear.
Log redaction regression.
```

If a failure mode exposes an undefined business rule, the agent must stop that specific behavior and record it as a TODO/manual-review decision rather than inventing a new payment policy.

---

## 11. Recommended Test Implementation Order

```text
1. Add test helpers/factories only if missing and scoped to Sales payment initialization.
2. Add valid initialization happy-path test.
3. Add invalid state tests and assert provider boundary is not called.
4. Add missing buyer_email test.
5. Add idempotency duplicate-call test.
6. Add provider failure/timeout tests.
7. Add config failure tests.
8. Add log redaction tests.
9. Add policy tests.
10. Add boundary creep tests.
11. Patch only the smallest VS-06B implementation gaps needed to pass.
```

---

## 12. TOON Coding-Agent Prompt

| Field | Content |
|---|---|
| Task | Add RED/GREEN test coverage for `VS-06C — Paystack Initialization Tests`. |
| Objective | Prove the VS-06B Paystack initialization flow is safe under valid checkout, invalid state, duplicate submit, provider failure, config failure, actor-policy, and log-redaction scenarios before webhook/verification work begins. |
| Output | Add/update focused tests under `test/fastcheck/sales/payments/`; patch only minimal VS-06B implementation gaps in `lib/fastcheck/sales/payments/transaction_initialization.ex` and related Paystack/Sales modules if tests fail for contract reasons; provide a final report listing tests added, gaps patched, and commands run. |
| Note | Use the existing repo testing style. Do not add webhook, verification, PaymentEvent processing, ticket issuance, Attendee mutation, scanner changes, WhatsApp/Meta behavior, or Redis inventory mutation. Required indexes/identities to verify: `unique(provider, provider_reference)`, `index(sales_order_id, status)`, idempotency key identity/index if implemented, `unique(sales_order_id)` for checkout sessions, and StateTransition entity index. Caching: none required. Redis: no inventory keys; only test bounded SETNX lock behavior if VS-06B already uses it. TTL: provider lock TTL must be bounded if present. Invalidation: none. PubSub: none unless already defined by VS-06B. Logs must redact secret key, Authorization header, access_code, authorization_url, raw provider responses, email, phone, and plaintext tokens. Tests must prove initialization never marks orders paid, never verifies payment, never consumes inventory, and never issues tickets. |

---

## 13. Copy-Paste Prompt for Coding Agent

```text
You are working on FastCheck Sales.

Implement feature planning pack VS-06C — Paystack Initialization Tests.

Goal:
Add focused RED/GREEN tests that prove the VS-06B Paystack transaction initialization flow is safe before webhook and verification work begins.

Context:
- Ash domain: FastCheck.Sales.
- Paystack provider modules from VS-06A must stay outside Ash resources.
- VS-06B initialization creates/returns a PaymentAttempt and safe authorization_url for a valid active checkout/order.
- Initialization is not proof of payment.
- Initialization must not verify payments, mark orders paid, consume inventory, issue tickets, create DeliveryAttempts, mutate Attendees, call WhatsApp/Meta, or touch scanner/mobile sync.

Required work:
1. Inspect the existing VS-06B initialization service and Paystack mock/test style.
2. Add tests for a valid active checkout/order initializing one Paystack transaction.
3. Add invalid order/checkout state tests proving Paystack is not called.
4. Add missing buyer_email or approved fallback-policy tests.
5. Add duplicate/idempotency tests proving repeated calls return the existing active attempt/link.
6. Add provider timeout/error/malformed-response tests.
7. Add missing/invalid Paystack config tests.
8. Add actor/policy tests for system/admin/operator/customer_session behavior.
9. Add log-redaction tests for secret key, Authorization header, access_code, authorization_url, raw provider response, buyer email, buyer phone, and plaintext tokens.
10. Add boundary tests proving no webhook, verification, PaymentEvent processing, paid state, ticket issuance, Attendee mutation, scanner changes, WhatsApp/Meta behavior, or Redis inventory consume/release/reserve behavior was added.
11. Patch production code only where required to make the tests pass according to the VS-06B contract.

Preferred test paths:
- test/fastcheck/sales/payments/paystack_initialization_test.exs
- test/fastcheck/sales/payments/paystack_initialization_idempotency_test.exs
- test/fastcheck/sales/payments/paystack_initialization_config_test.exs
- test/fastcheck/sales/payments/paystack_initialization_security_test.exs
- test/fastcheck/sales/payments/paystack_initialization_boundary_test.exs

Hard restrictions:
- Do not add Paystack webhook controller/routes/workers.
- Do not store/process PaymentEvent.
- Do not implement transaction verification.
- Do not call mark_paid_unverified or mark_paid_verified.
- Do not issue tickets.
- Do not create Attendees.
- Do not create DeliveryAttempts.
- Do not add WhatsApp/Meta behavior.
- Do not mutate scanner/mobile sync code.
- Do not mutate Redis inventory keys from initialization.
- Do not log secrets, PII, authorization URLs, access codes, raw provider responses, headers, or plaintext tokens.

Success:
All VS-06C tests pass. The final report lists files changed, tests added, exact commands run, RED failures seen, GREEN result, and any unresolved decisions.
```

---

## 14. Human Review Checklist

Use this checklist before accepting the agent output:

```text
[ ] Tests are focused on Paystack initialization only.
[ ] Happy-path test proves one valid active checkout/order creates one safe PaymentAttempt/link.
[ ] Invalid state tests prove Paystack is not called.
[ ] Missing buyer_email behavior is explicit and safe.
[ ] Duplicate initialization tests prove idempotency.
[ ] Provider failure tests do not mark order paid or consume inventory.
[ ] Config tests fail safely with no secret leakage.
[ ] Log redaction tests cover secret key, Authorization header, access_code, authorization_url, raw payload, email, phone, and tokens.
[ ] Policy tests match VS-01F actor model.
[ ] Boundary tests prove no webhook, verification, PaymentEvent, ticket issuance, Attendee, scanner, WhatsApp, or Redis inventory mutation.
[ ] Production code patches are minimal and only close VS-06B contract gaps.
[ ] No secrets were committed in fixtures, snapshots, logs, or docs.
[ ] Commands run are listed in the final report.
```

---

## 15. What Success Looks Like

A successful VS-06C implementation gives confidence that:

```text
Paystack payment links can be initialized safely.
Duplicate users/operators cannot create duplicate active attempts through repeated clicks.
Provider/config failures are safe and diagnosable without leaking secrets.
Initialization remains separate from webhook ingestion and transaction verification.
No ticket value is delivered until later verified-payment and issuance slices are complete.
```

The next slice can safely begin webhook ingestion without carrying unresolved initialization-test debt.

---

## 16. Next Slice

```text
VS-07A — Paystack Webhook Ingestion
```
