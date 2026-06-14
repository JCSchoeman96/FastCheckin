# FastCheck Sales Feature Planning Pack — VS-06A Paystack Client Boundary

**Pack ID:** `0019_VS-06A_paystack-client-boundary`  
**Slice:** `VS-06A`  
**Slice name:** Paystack Client Boundary  
**Version:** `v1.0`  
**Date:** 2026-06-12  
**Repository path:** `docs/fastcheck_sales/feature_packs/0019_VS-06A_paystack-client-boundary/`  
**Status:** Implementation planning pack — BLOCKED until `VS-21A` is imported/accepted or an equivalent repo logging/redaction baseline is explicitly accepted; provider-boundary code allowed only after that gate; Sales/checkout integration forbidden  
**Primary area:** Payments / Paystack / Provider boundary / Security / Tests  
**Depends on:** VS-00B, VS-21A *(must exist as an imported/accepted feature pack or be replaced by an explicitly accepted repo logging/redaction baseline)*  
**Blocks:** VS-06B, VS-07A, VS-07B, VS-07C, VS-19  
**Source docs:**

```text
docs/fastcheck_sales/SOURCE_DOCS/FastCheck_Sales_Ash_Atlas_Planning_Pack_v0.2.3_HARDENED.md
docs/fastcheck_sales/SOURCE_DOCS/FastCheck_Sales_Vertical_Slice_Roadmap_v1.1.3_HARDENED.md
```

---

## Repository alignment patch note

This normalized pack keeps the roadmap dependency on `VS-21A` explicit, but prevents it from being invisible.

The uploaded feature-pack set did not include a `VS-21A` feature pack. Therefore `VS-06A` is **not implementation-ready** until one of the following is true:

```text
1. A VS-21A Observability Naming and Log Redaction Foundation feature pack is imported and accepted; or
2. The repo has an explicitly accepted equivalent logging, telemetry, correlation-id, and redaction baseline.
```

Until that gate is accepted, a coding agent may review this pack and prepare notes, but must not implement Paystack provider-boundary code.

---

## 1. Purpose

This pack instructs a coding agent to implement the **Paystack provider boundary** for FastCheck Sales.

This is the first payment implementation slice. It must create safe, testable Paystack modules without connecting them to Sales checkout, Order state transitions, PaymentAttempt actions, webhook controllers, ticket issuance, WhatsApp, or admin UI.

The provider boundary should make later slices simple:

```text
VS-06A creates safe Paystack modules.
VS-06B connects a valid Sales checkout/order to Paystack transaction initialization.
VS-07A ingests Paystack webhooks.
VS-07B verifies transactions server-side.
VS-07C applies payment failure/mismatch/manual-review transitions.
VS-19 lets WhatsApp call the approved checkout/payment flow later.
```

The critical principle:

```text
Paystack is the payment provider.
FastCheck backend remains the payment authority.
WhatsApp, web checkout, and admin-assisted sales must never trust payment state until backend verification succeeds.
```

---

## 2. Ultimate Outcome

After VS-06A is complete:

```text
Paystack config is centralized and validated.
Paystack HTTP behavior is isolated behind plain Elixir modules.
Paystack webhook signature verification exists as a pure boundary function.
Paystack transaction initialize/verify provider-call functions exist but are not wired to Sales checkout yet.
All Paystack responses are normalized into safe success/error structs or tagged tuples.
All secret, access_code, authorization_url, raw payload, customer phone, and customer email data is redacted from logs.
Tests prove provider requests, headers, response parsing, error handling, timeout behavior, and log redaction.
No Ash resource action calls Paystack.
No Sales.Order, CheckoutSession, PaymentAttempt, or PaymentEvent workflow behavior is changed.
No webhook controller is added.
No ticket is issued.
```

This slice makes payment code available, not payment flow active.

---

## 3. Scope

### In scope

```text
Create FastCheck.Payments.Paystack.Config.
Create FastCheck.Payments.Paystack.Client.
Create FastCheck.Payments.Paystack.WebhookVerifier.
Create FastCheck.Payments.Paystack.TransactionInitializer provider-boundary module.
Create FastCheck.Payments.Paystack.TransactionVerifier provider-boundary module.
Create optional FastCheck.Payments.Paystack.ResponseSanitizer or Error module if useful.
Add application config/runtime config for Paystack base URL, public key, secret key, timeout, and environment.
Add behaviour/interface if the existing codebase uses behaviours/Mox for provider clients.
Add tests using Bypass/Mox or equivalent existing test style.
Add redaction tests for logs and inspected errors.
Add safe response normalization.
Add provider-boundary documentation.
```

### Out of scope

```text
No Sales checkout integration.
No Sales.Order state transitions.
No CheckoutSession transitions.
No PaymentAttempt actions.
No PaymentEvent persistence.
No Paystack webhook controller.
No Oban webhook worker.
No payment verification workflow.
No webhook-to-order matching.
No payment-after-expiry handling.
No WhatsApp payment messages.
No Meta API behavior.
No ticket issuance.
No Attendee creation.
No DeliveryAttempt behavior.
No admin dashboard/manual review UI.
No scanner changes.
No Redis inventory changes.
No raw provider payload display rules beyond redaction/sanitization helpers.
```

---

## 4. Required Pre-Implementation Discovery

Before editing code, the agent must inspect the existing repository and document the actual findings in its final report:

```text
Existing payment modules, if any.
Existing Req usage and HTTP client conventions.
Existing config/runtime.exs style.
Existing secrets/env var naming style.
Existing logging/telemetry conventions from the accepted `VS-21A` pack or the explicitly accepted equivalent repo logging/redaction baseline.
Existing test HTTP mocking style: Bypass, Mox, Req.Test, or project-specific helpers.
Existing JSON encoding/decoding conventions.
Existing error tuple/exception conventions.
Existing OTP app name and application environment conventions.
```

Do not create duplicate config, HTTP, logging, or test abstractions if project-approved patterns already exist.

If Paystack API details are uncertain, the agent must verify against current Paystack documentation before implementation and record the exact assumptions in the implementation notes. Do not hard-code guessed provider behavior without tests.

---

## 5. Domain and Boundary Details

### Ash domain referenced

```text
FastCheck.Sales
```

### Ash resources referenced only

```text
FastCheck.Sales.PaymentAttempt
FastCheck.Sales.PaymentEvent
FastCheck.Sales.Order
FastCheck.Sales.CheckoutSession
```

### Ash resources created or modified

```text
None.
```

### Plain Elixir modules to create or update

Preferred paths:

```text
lib/fastcheck/payments/paystack/config.ex
lib/fastcheck/payments/paystack/client.ex
lib/fastcheck/payments/paystack/webhook_verifier.ex
lib/fastcheck/payments/paystack/transaction_initializer.ex
lib/fastcheck/payments/paystack/transaction_verifier.ex
lib/fastcheck/payments/paystack/response_sanitizer.ex
lib/fastcheck/payments/paystack/error.ex
```

Use existing project naming conventions if they differ, but keep the namespace under:

```text
FastCheck.Payments.Paystack
```

### Possible config files

```text
config/runtime.exs
config/config.exs
config/test.exs
```

### Preferred test files

```text
test/fastcheck/payments/paystack/config_test.exs
test/fastcheck/payments/paystack/client_test.exs
test/fastcheck/payments/paystack/webhook_verifier_test.exs
test/fastcheck/payments/paystack/transaction_initializer_test.exs
test/fastcheck/payments/paystack/transaction_verifier_test.exs
test/fastcheck/payments/paystack/response_sanitizer_test.exs
test/fastcheck/payments/paystack/log_redaction_test.exs
```

---

## 6. Paystack Configuration Contract

### Required config values

```text
PAYSTACK_SECRET_KEY
PAYSTACK_PUBLIC_KEY
PAYSTACK_BASE_URL
PAYSTACK_TIMEOUT_MS
PAYSTACK_ENVIRONMENT
```

Recommended defaults:

```text
PAYSTACK_BASE_URL: "https://api.paystack.co"
PAYSTACK_TIMEOUT_MS: reasonable short backend timeout, e.g. 8_000 to 15_000 ms depending project standard
PAYSTACK_ENVIRONMENT: sandbox | live | test
```

### Config rules

```text
Production must fail fast if required Paystack secret config is missing.
Test environment may use explicit fake/test keys.
Secrets must not be logged.
Secret values must not appear in exception messages.
Runtime config should read from environment, not compile-time constants.
Never commit real Paystack keys.
Never place secrets in docs, pack files, tests, fixtures, or screenshots.
```

### Redaction rules

Always redact:

```text
secret_key
public_key when printed in full
Authorization header
access_code
authorization_url
raw provider response bodies
customer email
customer phone
metadata fields that may contain PII
```

Allowed safe log fields:

```text
provider: paystack
operation name
status category
http status
duration_ms
correlation_id
provider_reference hash or partial suffix only if required
error category
```

---

## 7. Paystack Client Contract

### `FastCheck.Payments.Paystack.Client`

Responsibilities:

```text
Own low-level HTTP request execution.
Add authorization header internally.
Apply base URL and timeout.
Encode JSON request bodies.
Decode JSON responses.
Normalize HTTP/network errors.
Call sanitizer before logging or returning debug metadata.
Expose functions used by TransactionInitializer and TransactionVerifier.
```

Non-responsibilities:

```text
No Sales order loading.
No CheckoutSession loading.
No PaymentAttempt creation.
No PaymentEvent creation.
No business state transitions.
No ticket issuance.
No Redis calls.
No WhatsApp calls.
```

Recommended API shape:

```text
request(method, path, body_or_params, opts \\ [])
```

or narrower provider functions if that matches the codebase better.

### HTTP behavior requirements

```text
Use Req if the project standard allows it.
Set Authorization internally using the configured secret key.
Set JSON content type where required.
Use explicit timeout.
Return tagged results instead of leaking raw exceptions to callers.
Normalize 2xx success separately from provider-declared failure states.
Normalize 4xx/5xx into safe error values.
Handle network timeout/refused/DNS failures as retryable or provider_unavailable errors.
```

---

## 8. Transaction Initializer Boundary

### Module

```text
FastCheck.Payments.Paystack.TransactionInitializer
```

### Purpose

Prepare and send a Paystack transaction-initialization request from a plain provider boundary.

VS-06A may expose the provider call function, but it must not decide whether a Sales order is valid for payment. That belongs to VS-06B.

### Recommended API shape

```text
initialize(params, opts \\ [])
```

Input should be provider-facing data only, not a Sales order struct:

```text
amount_cents
currency
email
reference
callback_url
metadata
channels/options if needed
```

### Rules

```text
Do not accept arbitrary client/public input directly.
Do not load Sales.Order.
Do not create PaymentAttempt.
Do not mark Order awaiting_payment/payment_pending.
Do not store authorization_url or access_code.
Do not log authorization_url or access_code.
Normalize returned provider_reference, authorization_url, access_code, and provider response into a safe struct or tagged tuple.
```

### Later VS-06B responsibility

VS-06B will:

```text
Validate Sales order/checkout state.
Build provider params from durable Sales data.
Call TransactionInitializer.initialize/2.
Create/update PaymentAttempt.
Store restricted raw provider response if required by policy.
Transition Order/CheckoutSession state.
```

VS-06A must not do those things.

---

## 9. Transaction Verifier Boundary

### Module

```text
FastCheck.Payments.Paystack.TransactionVerifier
```

### Purpose

Expose a provider-boundary function that can call Paystack server-side verification by reference.

VS-06A may implement the provider call. It must not apply verification to Sales state yet.

### Recommended API shape

```text
verify(reference, opts \\ [])
```

### Rules

```text
Reference must be provided by backend-generated provider_reference or accepted PaymentEvent data.
Do not update PaymentAttempt.
Do not mark payment verified.
Do not mark order paid.
Do not issue tickets.
Do not consume inventory.
Do not apply amount/currency/reference checks in Sales state.
Return normalized provider data for VS-07B to use later.
```

### Later VS-07B responsibility

VS-07B will:

```text
Load PaymentAttempt/Order.
Call TransactionVerifier.verify/2.
Check provider status.
Check amount.
Check currency.
Check provider reference.
Record verification result.
Move payment/order to verified/mismatch/manual_review states.
```

---

## 10. Webhook Verifier Boundary

### Module

```text
FastCheck.Payments.Paystack.WebhookVerifier
```

### Purpose

Verify Paystack webhook signatures as a pure boundary function.

### Recommended API shape

```text
valid_signature?(raw_body, signature_header, secret_key_or_config \\ default)
verify(raw_body, headers_or_signature, opts \\ [])
```

### Rules

```text
Use raw request body bytes/string exactly as received.
Do not verify after JSON re-encoding.
Do not parse business state here.
Do not persist PaymentEvent.
Do not enqueue Oban jobs.
Do not call transaction verification.
Return valid/invalid with safe reason only.
Do not log raw webhook body by default.
```

### Later VS-07A responsibility

VS-07A will:

```text
Read raw request body.
Call WebhookVerifier.
Persist PaymentEvent with signature_valid true/false according to policy.
Deduplicate events.
Enqueue worker.
Return quickly.
```

---

## 11. Response Normalization Contract

Provider boundary modules should return one of these shapes, adjusted to project conventions:

```text
{:ok, %FastCheck.Payments.Paystack.Result{...}}
{:error, %FastCheck.Payments.Paystack.Error{...}}
```

or:

```text
{:ok, map}
{:error, %{type: atom, message: binary, retryable?: boolean, safe_metadata: map}}
```

Required normalized error categories:

```text
:missing_config
:invalid_request
:unauthorized
:forbidden
:not_found
:rate_limited
:provider_error
:provider_unavailable
:timeout
:decode_error
:invalid_signature
:unknown_error
```

Rules:

```text
Returned errors must be safe to log.
Raw response bodies must not be included in normal error inspect output.
Sensitive provider fields must be removed or redacted.
Retryable vs non-retryable classification should be explicit where possible.
```

---

## 12. Security and PII Rules

This slice is security-sensitive even though it does not yet move money in Sales state.

### Forbidden logging

```text
Do not log PAYSTACK_SECRET_KEY.
Do not log Authorization header.
Do not log access_code.
Do not log authorization_url.
Do not log full provider raw response.
Do not log customer email or phone from initialize params.
Do not log webhook raw body by default.
```

### Safe debugging

Use:

```text
correlation_id
operation
http_status
provider_reference_hash_or_suffix
error_type
retryable?
duration_ms
```

### Metadata rules

Provider metadata sent to Paystack must be minimal:

```text
order public reference
event id if safe
source_channel
correlation_id
```

Avoid sending unnecessary PII in metadata. If customer phone/email is required by provider API, use only the required fields and redact them from logs.

---

## 13. Performance and Scaling Rules

```text
HTTP requests must have timeouts.
No provider call may happen inside an Ash resource action.
No provider call may happen inside a DB transaction in this slice.
No provider call may run in hot inventory reservation path.
No unbounded retries inside the client.
Client should be safe for Oban workers to call later.
Network failures should return retryable errors rather than blocking indefinitely.
```

Target behavior:

```text
Fast failure on missing config.
Bounded HTTP timeout.
No high-cardinality PII logs.
No large raw payload logs.
No accidental synchronous provider call from LiveView/Ash action.
```

---

## 14. RED/GREEN Test Plan

Tests must be written RED first where implementation does not yet exist, then made GREEN by the minimal provider-boundary implementation.

### 14.1 Config tests

#### RED

```text
Config test fails because missing required Paystack secret config is not detected.
Config test fails because production can boot with missing secret key.
Config test fails because secret key appears in inspected config/error output.
```

#### GREEN

```text
Config validates required secret values.
Test environment supports explicit fake keys.
Production-like validation fails fast on missing required keys.
Secret values are redacted from inspect/log output.
```

### 14.2 Client request tests

#### RED

```text
Client request test fails because module/function does not exist.
Client request test fails because Authorization header is missing.
Client request test fails because timeout is not applied.
Client request test fails because non-2xx response is not normalized.
Client request test fails because network failure raises raw exception instead of safe error.
```

#### GREEN

```text
Client sends requests to configured base URL.
Client adds Authorization internally.
Client uses JSON encoding/decoding.
Client applies timeout.
Client normalizes success, provider failure, HTTP failure, and network failure.
```

### 14.3 Transaction initializer tests

#### RED

```text
Initializer test fails because module/function does not exist.
Initializer test fails because raw customer email/access_code/authorization_url appears in logs.
Initializer test fails because initializer tries to load Sales.Order or PaymentAttempt.
```

#### GREEN

```text
Initializer calls provider endpoint with explicit provider params.
Initializer returns normalized provider response.
Initializer does not load or mutate Sales resources.
Initializer does not log sensitive fields.
```

### 14.4 Transaction verifier tests

#### RED

```text
Verifier test fails because module/function does not exist.
Verifier test fails because verifier mutates PaymentAttempt or Order state.
Verifier test fails because provider error is not normalized.
```

#### GREEN

```text
Verifier calls provider verification endpoint by reference.
Verifier returns normalized provider status/amount/currency/reference data.
Verifier does not mutate Sales state.
Verifier normalizes timeout, 404, unauthorized, and provider errors.
```

### 14.5 Webhook verifier tests

#### RED

```text
Webhook verifier test fails because module/function does not exist.
Valid signature test fails.
Invalid signature test fails.
Verifier incorrectly accepts a signature over re-encoded JSON instead of raw body.
Verifier logs raw webhook body.
```

#### GREEN

```text
Verifier accepts valid raw-body signature.
Verifier rejects invalid signatures.
Verifier returns safe invalid reason.
Verifier does not parse or persist PaymentEvent.
Verifier does not log raw webhook body by default.
```

### 14.6 Boundary tests

#### RED

```text
Test fails if Ash resource action calls FastCheck.Payments.Paystack.*.
Test fails if CheckoutSession/Order/PaymentAttempt logic is changed in this slice.
Test fails if webhook controller is added.
Test fails if Oban payment worker is added.
Test fails if ticket issuing or Attendee creation appears in Paystack modules.
```

#### GREEN

```text
Paystack modules are plain provider-boundary modules.
Ash resources have no Paystack HTTP calls.
No checkout/payment/ticket workflow is activated.
No webhook route/controller/worker exists from this slice.
Existing Sales checkout and scanner tests still pass.
```

### 14.7 Log redaction tests

#### RED

```text
Test fails because secret key appears in captured logs.
Test fails because Authorization header appears in captured logs.
Test fails because access_code or authorization_url appears in captured logs.
Test fails because email/phone appears in error logs.
```

#### GREEN

```text
Captured logs redact all secrets, tokens, authorization URLs, access codes, customer email, and phone.
Errors are safe to inspect.
Only safe metadata appears in logs.
```

---

## 15. Acceptance Criteria

A reviewer may mark this pack complete only when:

```text
Paystack config module exists and validates required settings safely.
Paystack client module exists and uses project-approved HTTP/test style.
TransactionInitializer provider-boundary module exists.
TransactionVerifier provider-boundary module exists.
WebhookVerifier pure signature-boundary module exists.
All modules are under FastCheck.Payments.Paystack or approved equivalent.
No Ash resource action calls Paystack.
No Sales checkout/order/payment workflow is changed.
No webhook controller/route/worker is introduced.
No ticket issuance, Attendee creation, Redis inventory mutation, or WhatsApp behavior is introduced.
Provider responses/errors are normalized.
Secrets and sensitive provider/customer data are redacted from logs and inspect output.
RED/GREEN tests exist and pass.
Existing scanner, checkout, and Sales resource tests still pass.
Final agent report lists discovered project conventions and confirms boundary safety.
```

---

## 16. Files to Create or Update

Allowed likely files:

```text
lib/fastcheck/payments/paystack/config.ex
lib/fastcheck/payments/paystack/client.ex
lib/fastcheck/payments/paystack/webhook_verifier.ex
lib/fastcheck/payments/paystack/transaction_initializer.ex
lib/fastcheck/payments/paystack/transaction_verifier.ex
lib/fastcheck/payments/paystack/response_sanitizer.ex
lib/fastcheck/payments/paystack/error.ex
config/runtime.exs
config/test.exs
test/fastcheck/payments/paystack/config_test.exs
test/fastcheck/payments/paystack/client_test.exs
test/fastcheck/payments/paystack/webhook_verifier_test.exs
test/fastcheck/payments/paystack/transaction_initializer_test.exs
test/fastcheck/payments/paystack/transaction_verifier_test.exs
test/fastcheck/payments/paystack/log_redaction_test.exs
```

Forbidden files/areas unless only reading for context:

```text
lib/fastcheck/sales/order.ex
lib/fastcheck/sales/checkout_session.ex
lib/fastcheck/sales/payment_attempt.ex
lib/fastcheck/sales/payment_event.ex
lib/fastcheck/sales/checkout.ex
lib/fastcheck_web/controllers/webhooks/paystack_controller.ex
lib/fastcheck/workers/paystack_webhook_worker.ex
lib/fastcheck/workers/verify_payment_worker.ex
lib/fastcheck/tickets/issuer.ex
lib/fastcheck/attendees/**
lib/fastcheck/mobile/**
lib/fastcheck/sales/inventory/**
lib/fastcheck/messaging/whatsapp/**
```

If the repository already has payment modules, update existing approved paths instead of duplicating them.

---

## 17. TOON Coding-Agent Prompt

| Field | Content |
|---|---|
| Task | Implement the VS-06A Paystack provider boundary for FastCheck Sales. |
| Objective | Create safe, testable plain Elixir Paystack modules for config, low-level HTTP, transaction initialization call, transaction verification call, and webhook signature verification without wiring them into Sales checkout or payment workflows yet. |
| Output | Add/update `lib/fastcheck/payments/paystack/config.ex`, `client.ex`, `transaction_initializer.ex`, `transaction_verifier.ex`, `webhook_verifier.ex`, optional sanitizer/error modules, runtime/test config, and Paystack boundary tests under `test/fastcheck/payments/paystack/`. |
| Note | Use existing project HTTP/test/config conventions. Prefer `Req` only if it matches project style. Do not add Paystack calls inside Ash resources. Do not modify `Order`, `CheckoutSession`, `PaymentAttempt`, or `PaymentEvent` workflows. Do not add webhook controllers/workers. Do not issue tickets or touch Attendees/scanner/Redis/WhatsApp. Validate config, normalize errors, use timeouts, redact `PAYSTACK_SECRET_KEY`, Authorization header, `access_code`, `authorization_url`, raw payloads, email, and phone. Write RED tests first, then minimal GREEN implementation. Include boundary tests proving no Sales/Ash workflow was activated. |

---

## 18. Copy-Paste Prompt for Coding Agent

```text
You are implementing FastCheck Sales feature slice VS-06A — Paystack Client Boundary.

Use Ash 3.x boundaries correctly: Ash/Sales resources own durable Sales state, but this slice must not modify Sales workflow behavior. Paystack must remain a plain Elixir provider boundary under FastCheck.Payments.Paystack.

Your task:
1. Inspect the repo for existing HTTP, config, logging, telemetry, and test-mocking conventions.
2. Create or update Paystack provider-boundary modules:
   - FastCheck.Payments.Paystack.Config
   - FastCheck.Payments.Paystack.Client
   - FastCheck.Payments.Paystack.WebhookVerifier
   - FastCheck.Payments.Paystack.TransactionInitializer
   - FastCheck.Payments.Paystack.TransactionVerifier
   - optional ResponseSanitizer/Error modules if useful.
3. Add runtime/test config for Paystack base URL, public key, secret key, timeout, and environment.
4. Implement safe request execution with explicit timeouts, internal Authorization header, JSON handling, safe error normalization, and no secret leakage.
5. Implement provider-call functions for transaction initialization and transaction verification, but do not connect them to Sales checkout, PaymentAttempt, PaymentEvent, or Order state yet.
6. Implement pure webhook signature verification using the raw request body. Do not add a webhook controller, route, Oban worker, or PaymentEvent persistence in this slice.
7. Add RED/GREEN tests for config validation, HTTP request behavior, initializer, verifier, webhook signature verification, error normalization, timeout/network failure handling, and log redaction.
8. Add boundary tests proving no Ash resource action, Sales checkout workflow, ticket issuing, Attendee creation, Redis inventory, WhatsApp, webhook controller, or payment worker behavior was added.

Forbidden:
- No Paystack HTTP calls inside Ash resource actions.
- No Sales.Order, CheckoutSession, PaymentAttempt, or PaymentEvent workflow changes.
- No webhook route/controller/worker.
- No payment verification workflow.
- No ticket issuing.
- No Attendee/scanner changes.
- No Redis mutation.
- No WhatsApp/Meta behavior.
- No logging of PAYSTACK_SECRET_KEY, Authorization header, access_code, authorization_url, raw provider payloads, email, or phone.

Keep the implementation minimal, testable, and boundary-clean. Final report must list files changed, tests run, discovered project conventions, and explicit confirmation that this slice did not activate payment flow.
```

---

## 19. Human Review Checklist

Before accepting the implementation, verify:

```text
Paystack modules exist under approved namespace.
Config reads from runtime env and fails safely when required config is missing.
No real secrets are committed.
HTTP calls use timeout.
Provider errors are normalized and safe to inspect/log.
Webhook verifier uses raw body.
Webhook verifier does not persist or enqueue anything.
Initializer/verifier do not load or mutate Sales state.
No Ash resource action calls Paystack.
No webhook controller/route/worker was added.
No PaymentAttempt/PaymentEvent state transition was implemented.
No ticket issuance, Attendee mutation, Redis mutation, or WhatsApp behavior was added.
Captured logs redact secrets, access_code, authorization_url, raw payloads, email, and phone.
Tests include failure paths, boundary checks, and log redaction.
Existing Sales/scanner tests still pass.
```

---

## 20. Next Slice

```text
VS-06B — Paystack Transaction Initialization
```

VS-06B will connect a valid Sales checkout/order state to this Paystack provider boundary and create/update durable `PaymentAttempt` state. That must not be done in VS-06A.
