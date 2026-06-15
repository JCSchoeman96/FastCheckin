# FastCheck Sales Feature Planning Pack — VS-22 End-to-End Sandbox Tests

**Pack ID:** `0044_VS-22_end-to-end-sandbox-tests`  
**Slice:** `VS-22`  
**Slice name:** End-to-End Sandbox Tests  
**Version:** `v1.0`  
**Date:** 2026-06-13  
**Status:** QA / hardening slice  
**Primary area:** QA / Integration / Sandbox / Failure-path proof  
**Repo truth:** `JCSchoeman96/FastCheckin`  
**Repository path:** `docs/fastcheck_sales/feature_packs/0044_VS-22_end-to-end-sandbox-tests/`  
**Source docs:** `docs/fastcheck_sales/SOURCE_DOCS/FastCheck_Sales_Ash_Atlas_Planning_Pack_v0.2.3_HARDENED.md`, `docs/fastcheck_sales/SOURCE_DOCS/FastCheck_Sales_Vertical_Slice_Roadmap_v1.1.3_HARDENED.md`  
**Depends on:** selected launch scope, VS-05, VS-06C, VS-07C, VS-09D, VS-10, VS-11, VS-14, VS-15A, VS-15B if admin refund/revoke is launch scope, VS-16–VS-20 if WhatsApp-first launch scope, VS-21A, VS-21B  
**Blocks:** VS-23B, VS-23C, paid production launch

---

## 1. Purpose

Create the full end-to-end sandbox test pack for FastCheck Sales.

This slice proves that the selected launch scope works across the real boundaries:

```text
checkout/order
Redis inventory hold
Paystack transaction initialization
Paystack webhook ingestion
server-side payment verification
ticket issuance
Attendee creation/linking
mobile sync/version/invalidation
secure ticket page
scanner acceptance
checkout expiry
revocation/refund scanner denial
WhatsApp payment/ticket flow if WhatsApp-first launch scope is enabled
```

This is a **test-only and hardening-only** slice.

Do not add new business features in this slice.

---

## 2. Launch Scope Rule

VS-22 must test the selected launch scope from VS-00D.

Strategic default:

```text
primary production launch: whatsapp_first_paid_core
secondary path: admin_assisted_sales first
web_checkout_sales later unless explicitly pulled forward
```

Required behavior:

```text
If whatsapp_first_paid_core is in launch scope, VS-22 must include WhatsApp E2E tests.
If admin_assisted_sales is in launch scope, VS-22 must include admin-assisted checkout tests.
If web_checkout_sales is in launch scope, VS-22 must include web checkout tests.
```

Do not mark VS-22 done by testing only isolated unit paths.

---

## 3. FastCheckin Current-State Findings

Use the existing FastCheckin test foundations:

```text
FastCheck.DataCase
FastCheckWeb.ConnCase
FastCheck.Fixtures
Oban testing: :manual in test
Swoosh.Adapters.Test in test
Ecto SQL Sandbox
FastCheck.TestSupport.Scans.InMemoryStore for mobile scan ingestion tests
```

Implication:

```text
E2E sandbox tests should compose the existing test case modules and fixtures.
Do not replace the test harness.
Add Sales-specific fixtures and sandbox helpers beside existing fixtures.
Keep external providers fake/stubbed by request functions or boundary modules.
```

---

## 4. Scope

### In scope

```text
Add E2E sandbox test modules.
Add Sales-specific fixture helpers.
Add fake Paystack provider helpers.
Add fake Meta/WhatsApp provider helpers.
Add fake clock/time helpers where needed.
Add Oban manual drain/assert helpers for Sales jobs.
Add Redis sandbox namespace helpers for inventory/session/dedupe tests.
Add full happy-path tests for selected launch scope.
Add critical failure-path tests.
Add concurrency/idempotency tests for duplicate webhooks/workers.
Add scanner/mobile acceptance and revocation-denial tests.
Add log-redaction assertions where practical.
Add test tags for slow/e2e/concurrency groups.
```

### Out of scope

```text
No new production business behavior.
No new provider HTTP behavior.
No new Paystack verification rules.
No new ticket issuance behavior.
No new scanner logic.
No new WhatsApp menu behavior.
No admin UI feature implementation.
No runbook finalization.
No load test tooling beyond bounded concurrency tests.
```

---

## 5. Recommended Files

Create or extend:

```text
test/fastcheck/sales/e2e/checkout_to_scanner_test.exs
test/fastcheck/sales/e2e/payment_failure_paths_test.exs
test/fastcheck/sales/e2e/checkout_expiry_recovery_test.exs
test/fastcheck/sales/e2e/revocation_scanner_visibility_test.exs
test/fastcheck/sales/e2e/admin_assisted_sales_test.exs
test/fastcheck/messaging/whatsapp/e2e/whatsapp_paid_core_test.exs
test/fastcheck/support/sales_fixtures.ex
test/fastcheck/support/fake_paystack.ex
test/fastcheck/support/fake_meta_whatsapp.ex
test/fastcheck/support/e2e_assertions.ex
test/fastcheck/support/redis_sandbox.ex
test/fastcheck/support/oban_assertions.exs
```

If project conventions prefer support files under `test/support`, use:

```text
test/support/sales_fixtures.ex
test/support/fake_paystack.ex
test/support/fake_meta_whatsapp.ex
test/support/e2e_assertions.ex
test/support/redis_sandbox.ex
test/support/oban_assertions.ex
```

Keep naming consistent with the existing `FastCheck.Fixtures`, `FastCheck.DataCase`, and `FastCheckWeb.ConnCase` patterns.

---

## 6. E2E Test Matrix

### 6.1 Core paid happy path

Required scenario:

```text
create active event
create active ticket offer
reserve inventory through checkout
create order + order line + checkout session
initialize Paystack transaction
receive Paystack webhook
verify transaction server-side
mark payment verified
issue ticket idempotently
create existing Attendee row
create TicketIssue row
aggregate event sync version
render secure ticket page
scanner accepts ticket
mobile sync sees attendee
```

Assertions:

```text
Inventory is consumed exactly once.
PaymentAttempt is verified once.
Order reaches ticket_issued only after Attendee and TicketIssue exist.
Scanner accepts issued active ticket.
No raw provider payload/token/phone/email is logged.
```

---

### 6.2 Duplicate webhook and worker retries

Required scenario:

```text
same Paystack webhook arrives twice
same VerifyPaymentWorker runs twice
same IssueTicketsWorker runs twice
```

Assertions:

```text
One PaymentAttempt reaches verified_success.
One TicketIssue per purchased ticket unit exists.
One Attendee per purchased ticket unit exists.
Order remains ticket_issued.
No duplicate ticket codes.
No duplicate inventory consumption.
StateTransition audit is idempotent or explicitly deduped by idempotency key.
```

---

### 6.3 Payment mismatch / manual review

Required scenarios:

```text
amount mismatch
currency mismatch
reference mismatch
provider failed/pending/abandoned
unmatched webhook event
```

Assertions:

```text
No ticket is issued.
No Attendee is created.
No scanner-visible ticket exists.
PaymentEvent remains queryable.
Order/PaymentAttempt moves to manual_review or approved failure state.
Operator dashboard/audit view can see safe summary without raw payload leak.
```

---

### 6.4 Checkout expiry and late payment

Required scenarios:

```text
checkout expires before payment
inventory hold is released once
late verified payment arrives while inventory is available
late verified payment arrives while inventory is unavailable
expiry worker races with payment verifier
```

Assertions:

```text
Expired hold does not oversell.
Duplicate expiry is idempotent.
Late verified payment follows VS-07C/VS-14 policy.
Unavailable inventory after late payment moves to manual_review.
No ticket is issued without valid inventory recovery/consume.
```

---

### 6.5 Revocation/refund scanner denial

Required scenario:

```text
issued ticket is revoked/refunded/cancelled through VS-15A/VS-15B core path
```

Assertions:

```text
TicketIssue becomes revoked.
Attendee.scan_eligibility becomes not_scannable.
AttendeeInvalidationEvent is appended.
Event sync aggregation is triggered.
Secure ticket page no longer shows ticket as valid.
Scanner returns TICKET_NOT_SCANNABLE.
Mobile DbAuthority rejects stale Redis/mobile hot-state scan.
```

---

### 6.6 WhatsApp-first paid core, if in launch scope

Required scenario:

```text
Meta inbound message starts/resumes conversation
customer uses Afrikaans-first number-only flow
customer selects event/offer/quantity
checkout/order created through approved Sales services
Paystack authorization link is sent
payment pending message is safe/reassuring
Paystack verified payment causes issuance
secure ticket link is sent through DeliveryAttempt path
outside 24-hour window uses utility template/fallback policy
```

Assertions:

```text
WhatsApp does not own payment authority.
WhatsApp does not mutate inventory directly.
WhatsApp does not issue tickets directly.
Outbound sends are deduped.
DeliveryAttempt rows capture attempts/failures/fallback.
No phone/message body/ticket URL/token is logged unsafely.
```

---

### 6.7 Admin-assisted sales, if in launch scope

Required scenario:

```text
admin/operator creates checkout link/order through selected secondary path
customer pays through Paystack link
same payment/issuance/scanner path is used
admin refund/revoke uses VS-15A core revocation path
```

Assertions:

```text
Admin-assisted path uses shared Sales core.
No admin path bypasses Redis inventory.
No admin path manually marks paid without verification.
No admin path issues tickets directly.
Audit reason is required for destructive actions.
```

---

## 7. Test Harness Rules

### Providers

Use fake provider boundaries, not live external network calls:

```text
FakePaystack initializes and verifies deterministic responses.
FakeMetaWhatsApp accepts outbound payloads and records sanitized attempt metadata.
Webhook tests should build signed payloads from fixtures.
```

### Redis

Use isolated test namespaces:

```text
sales:test:{test_id}:inventory:...
sales:test:{test_id}:whatsapp:session:...
sales:test:{test_id}:dedupe:...
```

Rules:

```text
Each test cleans its Redis namespace.
No test uses production-like global keys.
No test relies on wall-clock sleeps when a clock helper/fake now can be injected.
```

### Oban

Use existing test config:

```text
Oban testing: :manual
queues: false
plugins: false
```

Rules:

```text
Assert jobs are enqueued where expected.
Manually drain/perform jobs in deterministic order.
Never rely on background async behavior in tests.
```

### Database

Use existing SQL Sandbox:

```text
FastCheck.DataCase for DB tests.
FastCheckWeb.ConnCase for HTTP/controller tests.
```

Avoid async tests for concurrency, Redis, Oban, or shared named process paths unless explicitly isolated.

---

## 8. Required Test Tags

Use consistent tags:

```elixir
@tag :e2e
@tag :sales
@tag :payments
@tag :ticketing
@tag :scanner_visibility
@tag :whatsapp
@tag :slow
```

Recommended test commands:

```text
mix test --only e2e
mix test --only sales
mix test --only scanner_visibility
mix test --only whatsapp
mix test test/fastcheck/sales/e2e
```

---

## 9. Performance and Scaling Review

### Hot data

```text
Redis inventory holds, Redis WhatsApp dedupe/session keys, scanner/mobile hot state.
```

### Warm data

```text
Cachex/Redis dashboard aggregates, offer availability, active event/offer display.
```

### Cold data

```text
Postgres Sales resources, Attendees, PaymentEvents, TicketIssues, DeliveryAttempts, StateTransitions.
```

### Required checks

```text
E2E tests must assert no large unbounded admin list loads.
Inventory tests must prove no oversell under bounded concurrency.
Duplicate webhook/worker tests must prove idempotency.
Checkout expiry tests must prove released holds cannot be double-released or release consumed holds.
WhatsApp tests must prove dedupe and rate-limit posture.
```

### Index review gates

Before VS-22 is accepted, verify that all query paths used by tests have indexes:

```text
orders(status, inserted_at)
orders(public_reference)
checkout_sessions(status, expires_at)
payment_attempts(provider, provider_reference)
payment_events(provider, provider_event_id)
ticket_issues(sales_order_id, status)
ticket_issues(ticket_code)
ticket_issues(attendee_id)
delivery_attempts(sales_order_id, status)
delivery_attempts(ticket_issue_id, status)
state_transitions(entity_type, entity_id, inserted_at)
attendees(event_id, ticket_code)
attendee_invalidation_events(event_id, id)
```

---

## 10. Failure Modes to Prove

```text
Duplicate Paystack webhook.
Webhook before local PaymentAttempt exists.
Paystack verification timeout then retry.
Amount mismatch.
Currency mismatch.
Reference mismatch.
Checkout expiry before payment.
Late payment after expiry with inventory available.
Late payment after expiry with inventory unavailable.
IssueTicketsWorker duplicate execution.
Partial issuance recovery.
Scanner accepts issued active ticket.
Scanner denies revoked/refunded/cancelled ticket.
Secure ticket token expired/revoked.
WhatsApp duplicate inbound message.
WhatsApp outbound send timeout.
Meta 24-hour window closed.
Delivery template missing or rejected.
Redis unavailable during checkout.
Redis unavailable during WhatsApp session resume.
Admin destructive action without reason.
Operator tries forbidden destructive action.
Logs/Sentry redact PII/secrets/tokens.
```

---

## 11. Security and PII Requirements

Tests must assert redaction for:

```text
buyer_email
buyer_phone
phone_e164
WhatsApp wa_id
WhatsApp message body
Paystack authorization_url
Paystack access_code
provider raw payload
Meta access token
Meta app secret
delivery token plaintext
delivery_token_hash
qr_token_hash
secure ticket URL
```

Admin/operator views must show masked summaries only.

Customer-facing ticket pages must not expose raw token hashes or internal provider identifiers.

---

## 12. TOON Coding-Agent Prompt

| Field | Content |
|---|---|
| Task | Add VS-22 End-to-End Sandbox Tests for the selected FastCheck Sales launch scope in `JCSchoeman96/FastCheckin`. |
| Objective | Prove the full paid-ticket lifecycle and critical failure paths across checkout, Redis inventory, Paystack, ticket issuance, secure ticket page, scanner acceptance, revocation denial, and optional WhatsApp-first flow without adding new production behavior. |
| Output | E2E test modules under `test/fastcheck/sales/e2e/`; WhatsApp E2E tests under `test/fastcheck/messaging/whatsapp/e2e/` when launch scope includes WhatsApp; Sales fixtures/fakes under `test/support/` or repo-equivalent; deterministic fake Paystack/Meta helpers; Redis sandbox helper; Oban assertion helper; documentation comments for running `mix test --only e2e`. |
| Note | This is a QA-only slice. Do not add provider HTTP behavior, business state transitions, scanner logic, payment rules, ticket issuance logic, or admin UI features. Use existing `FastCheck.DataCase`, `FastCheckWeb.ConnCase`, `FastCheck.Fixtures`, SQL Sandbox, `Oban testing: :manual`, and Swoosh test adapter. Redis keys must be namespaced per test and cleaned. Required indexes: orders/status/public_reference, checkout_sessions(status,expires_at), payment_attempts(provider,provider_reference), payment_events(provider,provider_event_id), ticket_issues(ticket_code/attendee_id/sales_order_id), delivery_attempts(order/status), state_transitions(entity_type,entity_id,inserted_at), attendees(event_id,ticket_code), attendee_invalidation_events(event_id,id). Cache/TTL: use test namespaces; do not sleep on real TTLs; inject fake now/clock. PubSub: assert broadcasts only where existing slices define them. Boundary rules: no real Paystack/Meta calls, no background async assumptions, no raw PII/tokens in logs, no scanner rewrite, no inventory bypass. |
| Success | `mix test --only e2e` proves happy path, duplicate webhook/worker idempotency, payment mismatch/manual review, checkout expiry/late payment, ticket issuance, scanner acceptance, revocation scanner denial, secure ticket invalidation, and WhatsApp-first payment/ticket flow if selected for launch. |

---

## 13. Copy-Paste Prompt for Coding Agent

```text
You are implementing FastCheck Sales VS-22 — End-to-End Sandbox Tests in JCSchoeman96/FastCheckin.

Goal:
Add deterministic sandbox E2E tests for the selected Sales launch scope without adding production business behavior.

Use repo truth:
- `FastCheck.DataCase` provides SQL Sandbox and imports `FastCheck.Fixtures`.
- `FastCheckWeb.ConnCase` provides Phoenix connection tests.
- `FastCheck.Fixtures` already creates events and attendees.
- test config uses `Oban testing: :manual`, `Swoosh.Adapters.Test`, SQL Sandbox, and `FastCheck.TestSupport.Scans.InMemoryStore`.

Create tests for:
1. checkout -> Redis hold -> Paystack initialize -> webhook -> verify -> issue -> Attendee -> TicketIssue -> secure page -> scanner accepts.
2. duplicate webhook + duplicate VerifyPaymentWorker + duplicate IssueTicketsWorker.
3. amount/currency/reference mismatch -> manual_review, no ticket, no attendee.
4. checkout expiry -> inventory release -> late payment policy.
5. issued ticket revocation/refund/cancel -> scanner returns TICKET_NOT_SCANNABLE.
6. secure ticket token expired/revoked -> no valid QR.
7. WhatsApp-first flow if selected launch scope includes it.
8. admin-assisted flow if selected launch scope includes it.
9. log/Sentry redaction for PII, provider secrets, payment URLs, WhatsApp bodies, and ticket tokens.

Add helper modules only under test support:
- Sales fixtures.
- Fake Paystack.
- Fake Meta WhatsApp.
- Redis sandbox namespace helper.
- Oban assertion/manual drain helper.
- E2E assertions helper.

Do not:
- call live Paystack or Meta APIs
- add new production business transitions
- add new scanner behavior
- add new ticket issuance behavior
- add new admin UI features
- rely on background async workers
- use production Redis keys
- use wall-clock sleeps for TTL behavior
- log or assert raw PII/tokens

Run target:
- `mix test --only e2e`
- keep individual files runnable with `mix test path/to/file.exs`
```

---

## 14. Human Review Checklist

```text
[ ] Tests are in FastCheckin repo conventions.
[ ] Existing DataCase/ConnCase are reused.
[ ] Provider calls are faked/stubbed.
[ ] Oban is manually asserted/drained.
[ ] Redis keys are test-namespaced and cleaned.
[ ] Core happy path is covered.
[ ] Duplicate webhook/worker idempotency is covered.
[ ] Payment mismatches are covered.
[ ] Checkout expiry and late payment are covered.
[ ] Ticket issuance and partial retry are covered.
[ ] Scanner accepts valid issued ticket.
[ ] Scanner denies revoked/refunded/cancelled ticket.
[ ] Secure ticket token invalidation is covered.
[ ] WhatsApp-first path is covered if in launch scope.
[ ] Admin-assisted path is covered if in launch scope.
[ ] Redaction assertions cover Paystack, Meta, PII, and ticket tokens.
[ ] No production feature behavior was added to make tests pass.
[ ] No real external network calls are made.
[ ] No large unbounded dashboard/admin queries are introduced.
```

---

## 15. Next Slice

```text
VS-23A — Launch Runbook Draft
```
