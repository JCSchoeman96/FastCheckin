# FastCheck Sales Feature Planning Pack — VS-01C Checkout and Payment Resource Skeletons

**Pack ID:** `0007_VS-01C_checkout-and-payment-resource-skeletons`  
**Repository path:** `docs/fastcheck_sales/feature_packs/0007_VS-01C_checkout-and-payment-resource-skeletons`  
**Slice:** `VS-01C`  
**Slice name:** Checkout and Payment Resource Skeletons  
**Version:** `v1.0`  
**Date:** 2026-06-12  
**Status:** Ready for implementation only after VS-01B is accepted and VS-00A/VS-00B/VS-00C/VS-00D decisions are available  
**Primary area:** Ash / DB / Checkout and Payment Skeletons  
**Depends on:** VS-01B  
**Blocks:** VS-01D, VS-01F, VS-01G, VS-05, VS-06B, VS-07A, VS-07B, VS-07C  
**Source docs:**

```text
docs/fastcheck_sales/SOURCE_DOCS/FastCheck_Sales_Ash_Atlas_Planning_Pack_v0.2.3_HARDENED.md
docs/fastcheck_sales/SOURCE_DOCS/FastCheck_Sales_Vertical_Slice_Roadmap_v1.1.3_HARDENED.md
```

---

> **Normalization note:** This pack was structurally normalized for the `docs/fastcheck_sales/feature_packs/` repo layout. Source-doc references are repo-relative. No semantic scope changes were made in this batch.

---

## 1. Purpose

This pack creates the Ash resource skeletons for the checkout and payment persistence layer:

```text
FastCheck.Sales.CheckoutSession
FastCheck.Sales.PaymentAttempt
FastCheck.Sales.PaymentEvent
```

This slice gives the Sales domain durable tables for checkout intent, Paystack transaction attempts, and raw Paystack webhook events.

This is still a **skeleton slice**. It must not implement checkout workflow behavior, Redis inventory mutation, Paystack HTTP calls, webhook controllers, transaction verification, Oban workers, admin UI, ticket issuance, or WhatsApp logic.

The strategic direction remains:

```text
FastCheck Sales is multi-channel, but WhatsApp is first.

Primary production customer channel:
  WhatsApp via Meta Cloud API

Secondary supported Sales paths:
  admin-assisted sales
  web checkout sales
  internal pilot sales

All channels must use the same Sales core.
No channel may bypass Redis inventory, Paystack verification, ticket issuance, delivery audit, or scanner-safe revocation.
```

---

## 2. Ultimate Outcome

After VS-01C is complete:

```text
The FastCheck.Sales Ash domain registers three additional resources:
  CheckoutSession
  PaymentAttempt
  PaymentEvent

The database has three corresponding tables:
  sales_checkout_sessions
  sales_payment_attempts
  sales_payment_events

Each resource compiles.
Each resource has required attributes, timestamps, identities, indexes, and basic read actions.
CheckoutSession belongs to Order.
PaymentAttempt belongs to Order.
PaymentEvent stores raw provider events safely but does not process them.
No checkout flow, Redis mutation, Paystack HTTP, webhook controller, verification worker, or payment state-machine logic exists yet.
RED/GREEN tests prove resource skeletons, migrations, indexes, relationships, and forbidden boundaries.
```

---

## 3. Scope

### In scope

```text
Inspect existing Ash, Ecto, Repo, migration, and test conventions.
Create FastCheck.Sales.CheckoutSession resource skeleton.
Create FastCheck.Sales.PaymentAttempt resource skeleton.
Create FastCheck.Sales.PaymentEvent resource skeleton.
Register these resources in FastCheck.Sales.
Create database migrations for the three tables.
Add required identities and indexes for this slice.
Add basic read/list actions only.
Add relationship declarations to Order where appropriate.
Add skeleton tests for resource registration, migrations, fields, relationships, indexes, and forbidden boundaries.
Add/update slice documentation.
Run format, compile, migration, and test commands.
```

### Out of scope

```text
No TicketIssue resource.
No DeliveryAttempt resource.
No Conversation resource.
No Redis inventory ledger implementation.
No ReservationLedger module.
No Redis Lua scripts.
No checkout session creation workflow.
No inventory hold creation, release, consume, or expiry behavior.
No Paystack client implementation.
No Paystack transaction initialization.
No Paystack webhook controller.
No Paystack webhook verification.
No Paystack transaction verification.
No PaymentEvent processing worker.
No Oban workers.
No WhatsApp/Meta API code.
No QR generation.
No delivery-token generation.
No Attendee creation.
No scanner changes.
No Android/mobile API changes.
No LiveView/admin UI.
No generic update_status action.
No state-machine workflow actions.
```

---

## 4. Required Pre-Implementation Decisions

The coding agent must read the accepted outputs from VS-00A, VS-00B, VS-00C, VS-00D, VS-01A, and VS-01B before implementation.

### Tenant / organization decision

This slice must follow the accepted tenant model from earlier planning.

Rules:

```text
If multi_tenant or future_multi_tenant_prepared is accepted:
  include organization_id or the approved tenant/owner key on all three tables if the prior resource skeletons use it.
  ensure tenant/event scoping can be enforced later in VS-01F policies.

If single_tenant is accepted:
  do not add organization_id blindly.
  document that the first release is intentionally single-tenant.

If no decision exists:
  stop and report blocker. Do not create migrations.
```

### State-machine decision

VS-00A must be accepted before this slice.

Rules:

```text
CheckoutSession.status must use the accepted checkout-session state vocabulary.
PaymentAttempt.status must use the accepted payment-attempt state vocabulary.
PaymentEvent.processing_status must use the accepted event-processing vocabulary.
No transition actions are implemented in VS-01C.
```

### Security / PII / raw payload decision

VS-00B must be accepted before this slice.

Rules:

```text
Raw provider payload fields are allowed only as restricted persistence fields.
No raw provider payloads may be logged in tests or code.
No operator-facing raw payload access is implemented in this slice.
Field-level policies land in VS-01F.
Retention policy is documented by VS-00B and must be referenced in slice docs.
```

### Inventory recovery decision

VS-00C must be accepted before this slice.

Rules:

```text
CheckoutSession may store redis_hold_key and hold metadata.
CheckoutSession must not mutate Redis.
No Redis availability, reservation, hold, release, consume, or expiry logic is implemented here.
```

---

## 5. Ash Domain and Resource Details

### Ash domain to update

```text
lib/fastcheck/sales.ex
```

Update the existing `FastCheck.Sales` domain from VS-01A/VS-01B to also register:

```text
FastCheck.Sales.CheckoutSession
FastCheck.Sales.PaymentAttempt
FastCheck.Sales.PaymentEvent
```

Do not register resources from later slices.

### Resources created in this slice

```text
lib/fastcheck/sales/checkout_session.ex
lib/fastcheck/sales/payment_attempt.ex
lib/fastcheck/sales/payment_event.ex
```

### Resources from previous slices that may be referenced

```text
FastCheck.Sales.Order
FastCheck.Sales.StateTransition
```

Do not modify previous resources beyond the minimum relationship additions needed by this slice. If relationship additions require touching `Order`, keep them declarative only and do not add workflow behavior.

---

## 6. Resource Contract — CheckoutSession

### Resource module

```text
lib/fastcheck/sales/checkout_session.ex
```

### Table

```text
sales_checkout_sessions
```

### Purpose

`CheckoutSession` stores durable checkout intent and references the Redis inventory hold key, but Redis remains the hot reservation authority.

### Required fields

```text
id
organization_id       # only if accepted tenant model requires it
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

### Field guidance

```text
sales_order_id: foreign key to sales_orders.id
status: constrained checkout-session state value
redis_hold_key: nullable string until hold is attached
hold_token: opaque internal hold token/hash if required by accepted inventory contract
hold_quantity: integer, non-negative
state_data: map/jsonb
lock_version: integer optimistic-lock field, default 1 or project convention
all timestamps: UTC
```

### Required states

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

### Required relationships

```text
belongs_to :order, FastCheck.Sales.Order
```

### Required identities / indexes

```text
unique(sales_order_id)
unique(redis_hold_key) where redis_hold_key is not null
index(status, expires_at)
index(sales_order_id, status)
```

If tenanting is accepted, add tenant-aware composite indexes following the accepted convention.

### Allowed actions in this slice

```text
basic read
basic get_by_id
safe list actions if project convention requires them
```

### Forbidden actions in this slice

```text
create_session
attach_inventory_hold
mark_payment_link_sent
expire_session
release_session
any action that mutates Redis
any action that changes Order status
any action that initializes Paystack
any generic update_status action
```

---

## 7. Resource Contract — PaymentAttempt

### Resource module

```text
lib/fastcheck/sales/payment_attempt.ex
```

### Table

```text
sales_payment_attempts
```

### Purpose

`PaymentAttempt` stores durable Paystack transaction attempt state. It is not a Paystack client, verifier, webhook handler, or payment authority by itself.

### Required fields

```text
id
organization_id       # only if accepted tenant model requires it
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

### Field guidance

```text
sales_order_id: foreign key to sales_orders.id
provider: string/enum, Paystack expected for first implementation
provider_reference: provider-scoped transaction reference
idempotency_key: string, nullable until implementation defines usage
amount_cents: integer, non-negative
currency: uppercase ISO 4217 string
verification_attempt_count: integer, default 0
raw_initialize_response: restricted jsonb/map field, never logged
raw_verify_response: restricted jsonb/map field, never logged
status: constrained payment-attempt state value
```

### Required states

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

Note: later slices must not downgrade `verified_success` to `duplicate`. Duplicate webhook/verification handling should return idempotent success and record duplicate handling on PaymentEvent, metadata, or worker logs.

### Required relationships

```text
belongs_to :order, FastCheck.Sales.Order
```

Optional later relationship:

```text
PaymentAttempt has many PaymentEvent by provider_reference/provider_reference.
```

Do not over-engineer this relationship in VS-01C if Ash cannot represent it cleanly without workflow assumptions. It may remain documented until VS-07.

### Required identities / indexes

```text
unique(provider, provider_reference)
index(sales_order_id, status)
index(provider, status)
index(last_verified_at)
```

If tenanting is accepted, add tenant-aware composite indexes following the accepted convention.

### Allowed actions in this slice

```text
basic read
basic get_by_id
safe list actions if project convention requires them
```

### Forbidden actions in this slice

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
any Paystack HTTP call
any transaction initialization
any transaction verification
any webhook handling
any Order status mutation
any generic update_status action
```

---

## 8. Resource Contract — PaymentEvent

### Resource module

```text
lib/fastcheck/sales/payment_event.ex
```

### Table

```text
sales_payment_events
```

### Purpose

`PaymentEvent` stores raw provider webhook events durably and safely. It does not process, verify, or mutate orders in this slice.

### Required fields

```text
id
organization_id       # only if accepted tenant model requires it
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

### Field guidance

```text
provider: string/enum, Paystack expected for first implementation
provider_event_id: nullable if provider does not provide stable event id
provider_reference: provider transaction reference used for later matching
signature_valid: boolean, nullable or false by default depending webhook policy
payload_hash: string hash of raw payload for dedupe
raw_payload: restricted jsonb/map field, never logged
received_at: UTC timestamp set when persisted later
processing_status: constrained processing state value
processing_attempt_count: integer, default 0
```

### Required processing statuses

```text
stored
processing_started
processed
duplicate
unmatched
failed
manual_review
```

### Required relationships

```text
No hard foreign-key relationship to PaymentAttempt is required in VS-01C.
```

Rationale:

```text
Webhooks may arrive before a local PaymentAttempt exists.
Unmatched events must remain durable and retryable.
Matching by provider_reference is handled in later payment-processing slices.
```

### Required identities / indexes

```text
unique(provider, provider_event_id) where provider_event_id is not null
unique(provider, payload_hash) where provider_event_id is null
index(provider_reference)
index(processing_status, inserted_at)
```

If tenanting is accepted, add tenant-aware composite indexes following the accepted convention where provider payloads can be tenant-scoped.

### Allowed actions in this slice

```text
basic read
basic get_by_id
safe list actions if project convention requires them
```

### Forbidden actions in this slice

```text
store_webhook_event
mark_processing_started
mark_processed
mark_duplicate
mark_unmatched
mark_failed
any webhook controller behavior
any webhook signature verification
any transaction verification
any PaymentAttempt status mutation
any Order status mutation
any Oban enqueue
any generic update_status action
```

---

## 9. Required Migration Outputs

Create migrations following the project’s existing migration naming conventions.

Expected tables:

```text
sales_checkout_sessions
sales_payment_attempts
sales_payment_events
```

Expected migration behavior:

```text
Use explicit foreign keys where appropriate.
Use partial unique indexes where required.
Use jsonb/map columns for state_data and raw provider payload fields according to project convention.
Use integer cents for money.
Use UTC timestamps.
Use lock_version integer field where specified.
Do not create later-slice tables.
Do not modify scanner, attendee, event, Tickera, or Android/mobile tables.
```

Recommended migration file patterns:

```text
priv/repo/migrations/*create_sales_checkout_sessions*.exs
priv/repo/migrations/*create_sales_payment_attempts*.exs
priv/repo/migrations/*create_sales_payment_events*.exs
```

---

## 10. RED / GREEN Test Plan

This slice must use RED/GREEN tests. The agent should write failing tests first, then implement until they pass.

### RED tests must fail before implementation when

```text
FastCheck.Sales.CheckoutSession does not exist.
FastCheck.Sales.PaymentAttempt does not exist.
FastCheck.Sales.PaymentEvent does not exist.
FastCheck.Sales does not register the three VS-01C resources.
sales_checkout_sessions table does not exist.
sales_payment_attempts table does not exist.
sales_payment_events table does not exist.
CheckoutSession required fields are missing.
PaymentAttempt required fields are missing.
PaymentEvent required fields are missing.
CheckoutSession does not belong to Order.
PaymentAttempt does not belong to Order.
Required unique indexes are missing.
Required query-path indexes are missing.
State/status fields allow arbitrary undocumented values when the project supports constraints.
Raw payload fields are logged or exposed in test output.
Any forbidden Paystack, Redis, webhook, Oban, ticketing, scanner, WhatsApp, or admin UI code is added.
Any generic update_status action exists.
Any workflow action from later slices is implemented too early.
```

### GREEN tests must pass after implementation when

```text
mix format passes.
mix compile passes.
The three resources compile with AshPostgres.
FastCheck.Sales registers exactly the prior resources plus the three VS-01C resources.
Migrations create only the intended VS-01C tables.
Required fields exist with appropriate types/conventions.
Required relationships to Order exist where specified.
Required identities and indexes exist.
Partial unique indexes exist for PaymentEvent dedupe rules.
No Paystack HTTP code exists.
No webhook controller code exists.
No Redis mutation code exists.
No Oban payment worker exists.
No ticket issuance code exists.
No scanner/mobile changes exist.
No raw provider payloads are logged.
No generic update_status action exists.
No state-machine workflow actions exist yet.
```

---

## 11. Suggested Test File Paths

Use existing project test conventions. If no better convention exists, use:

```text
test/fastcheck/sales/checkout_session_resource_test.exs
test/fastcheck/sales/payment_attempt_resource_test.exs
test/fastcheck/sales/payment_event_resource_test.exs
test/fastcheck/sales/vs_01c_boundary_test.exs
```

Boundary tests should verify this slice does **not** add:

```text
lib/fastcheck/payments/paystack/client.ex
lib/fastcheck_web/controllers/webhooks/paystack_controller.ex
lib/fastcheck/workers/paystack_webhook_worker.ex
lib/fastcheck/workers/verify_payment_worker.ex
lib/fastcheck/sales/inventory/reservation_ledger.ex
lib/fastcheck/tickets/issuer.ex
lib/fastcheck_web/live/sales/*
```

---

## 12. Performance and Scaling Review

### Data layer classification

```text
CheckoutSession: cold durable Postgres intent + references Redis hot hold key later.
PaymentAttempt: cold durable Postgres payment attempt record.
PaymentEvent: cold durable Postgres raw webhook/event audit record.
Redis: not used by implementation in this slice.
Cachex: not used by implementation in this slice.
```

### Scaling requirements

```text
No high-concurrency checkout path is added yet.
No Redis hot path is added yet.
No dashboard table scans should be introduced.
PaymentEvent indexes must support lookup by provider_reference and processing_status.
CheckoutSession indexes must support expiry queries by status/expires_at.
PaymentAttempt indexes must support provider/status and order/status queries.
Raw payload fields must not be loaded casually in future list views.
```

### Required future indexes enabled by this slice

```text
Checkout expiry worker:
  sales_checkout_sessions(status, expires_at)

Payment verification worker:
  sales_payment_attempts(provider, status)
  sales_payment_attempts(last_verified_at)

Webhook processing worker:
  sales_payment_events(processing_status, inserted_at)
  sales_payment_events(provider_reference)
```

---

## 13. Security Review

This slice introduces sensitive payment-provider persistence fields, so the agent must be conservative.

Rules:

```text
Do not log authorization_url.
Do not log access_code.
Do not log raw_initialize_response.
Do not log raw_verify_response.
Do not log raw_payload.
Do not expose raw provider payloads in operator-facing reads.
Do not create admin UI in this slice.
Do not create public API endpoints in this slice.
Do not create customer-facing reads for PaymentAttempt or PaymentEvent.
```

Policy enforcement lands in VS-01F, but this slice must not create code that makes safe policy enforcement harder later.

---

## 14. Files the Agent May Touch

Allowed paths:

```text
lib/fastcheck/sales.ex
lib/fastcheck/sales/checkout_session.ex
lib/fastcheck/sales/payment_attempt.ex
lib/fastcheck/sales/payment_event.ex
priv/repo/migrations/*sales_checkout_sessions*.exs
priv/repo/migrations/*sales_payment_attempts*.exs
priv/repo/migrations/*sales_payment_events*.exs
test/fastcheck/sales/*checkout_session*test.exs
test/fastcheck/sales/*payment_attempt*test.exs
test/fastcheck/sales/*payment_event*test.exs
test/fastcheck/sales/*vs_01c*test.exs
docs/fastcheck_sales/slices/VS-01C_CHECKOUT_AND_PAYMENT_RESOURCE_SKELETONS.md
```

Conditionally allowed:

```text
lib/fastcheck/sales/order.ex
```

Only for declarative relationship additions. No new workflow actions.

Forbidden paths:

```text
lib/fastcheck/sales/ticket_issue.ex
lib/fastcheck/sales/delivery_attempt.ex
lib/fastcheck/sales/conversation.ex
lib/fastcheck/sales/inventory/*
lib/fastcheck/payments/paystack/*
lib/fastcheck/messaging/whatsapp/*
lib/fastcheck/tickets/*
lib/fastcheck/workers/*
lib/fastcheck_web/controllers/webhooks/*
lib/fastcheck_web/live/sales/*
lib/fastcheck/attendees/*
lib/fastcheck/events/*
lib/fastcheck/mobile/*
```

---

## 15. Acceptance Criteria

The slice is accepted only when:

```text
CheckoutSession resource exists and compiles.
PaymentAttempt resource exists and compiles.
PaymentEvent resource exists and compiles.
FastCheck.Sales registers the three new resources.
Migrations create exactly the three intended VS-01C tables.
Required fields exist with expected conventions.
Required identities and indexes exist.
CheckoutSession belongs to Order.
PaymentAttempt belongs to Order.
PaymentEvent remains durable and matchable even when no PaymentAttempt exists.
RED/GREEN tests are present and passing.
No Paystack HTTP, webhook processing, Redis mutation, Oban worker, ticket issuing, scanner, WhatsApp, or admin UI code is added.
No generic update_status action exists.
No raw provider payloads are logged.
Slice documentation is added or updated.
```

---

## 16. TOON Coding-Agent Prompt

| Field | Content |
|---|---|
| Task | Implement VS-01C Checkout and Payment Resource Skeletons for FastCheck Sales. |
| Objective | Add durable Ash/Postgres skeletons for checkout sessions, payment attempts, and payment events so later checkout and Paystack slices have safe database contracts. |
| Output | Create `lib/fastcheck/sales/checkout_session.ex`, `lib/fastcheck/sales/payment_attempt.ex`, `lib/fastcheck/sales/payment_event.ex`; register them in `lib/fastcheck/sales.ex`; add migrations for `sales_checkout_sessions`, `sales_payment_attempts`, and `sales_payment_events`; add RED/GREEN tests and slice docs. |
| Note | Use Ash 3.x and existing project conventions. Keep this skeleton-only. Do not implement checkout workflow actions, Redis mutation, Paystack HTTP, webhook controllers, transaction verification, Oban workers, ticket issuing, WhatsApp logic, admin UI, scanner changes, or generic `update_status`. Add required fields, relationships, identities, partial unique indexes, and query indexes. Respect VS-00B security: never log `authorization_url`, `access_code`, raw Paystack responses, or raw webhook payloads. Respect VS-00C: CheckoutSession may store Redis hold keys but must not mutate Redis. Tests must fail before implementation and pass after implementation. |

---

## 17. Copy-Paste Prompt for Coding Agent

```text
You are implementing FastCheck Sales slice VS-01C — Checkout and Payment Resource Skeletons.

Read these source documents first:
- FastCheck_Sales_Ash_Atlas_Planning_Pack_v0.2.3_HARDENED.md
- FastCheck_Sales_Vertical_Slice_Roadmap_v1.1.3_HARDENED.md
- Accepted outputs from VS-00A, VS-00B, VS-00C, VS-00D, VS-01A, and VS-01B

Goal:
Create Ash resource skeletons and migrations for:
- FastCheck.Sales.CheckoutSession
- FastCheck.Sales.PaymentAttempt
- FastCheck.Sales.PaymentEvent

Register these resources in FastCheck.Sales.

Keep this slice skeleton-only.

Allowed:
- resource modules
- migrations
- basic read/list actions
- required fields
- required identities/indexes
- CheckoutSession belongs_to Order
- PaymentAttempt belongs_to Order
- tests
- slice documentation

Forbidden:
- Paystack HTTP client
- Paystack webhook controller
- Paystack webhook signature verification
- Paystack transaction initialization
- Paystack transaction verification
- Redis mutation
- ReservationLedger
- Oban workers
- ticket issuing
- WhatsApp/Meta API
- scanner changes
- admin UI
- generic update_status
- state-machine workflow actions

Write RED tests first for missing resources, missing tables, missing indexes, missing relationships, and forbidden boundary creep.
Then implement until GREEN.

Run formatting, compile, migrations, and relevant tests.
Report all files changed, commands run, test results, and any blockers.
```

---

## 18. Human Review Checklist

Before accepting this slice, confirm:

```text
The agent did not create Paystack client/controller/worker code.
The agent did not create Redis inventory code.
The agent did not create checkout workflow actions.
The agent did not create ticket issuing code.
The agent did not modify scanner, attendee reconciliation, Android/mobile API, or event sync logic.
The three resources are registered in FastCheck.Sales.
The migrations create exactly the intended tables.
Partial unique indexes are present where required.
Raw provider payload fields are not logged or exposed.
Tests prove both existence and boundary restrictions.
The implementation leaves later VS-05/VS-07 behavior unimplemented.
```
