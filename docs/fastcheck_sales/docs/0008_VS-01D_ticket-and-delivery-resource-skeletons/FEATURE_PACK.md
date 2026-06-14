# FastCheck Sales Feature Planning Pack — VS-01D Ticket and Delivery Resource Skeletons

**Pack ID:** `0008_VS-01D_ticket-and-delivery-resource-skeletons`  
**Repository path:** `docs/fastcheck_sales/feature_packs/0008_VS-01D_ticket-and-delivery-resource-skeletons`  
**Slice:** `VS-01D`  
**Slice name:** Ticket and Delivery Resource Skeletons  
**Version:** `v1.0`  
**Date:** 2026-06-12  
**Status:** Ready for implementation only after VS-01C is accepted and VS-00A/VS-00B/VS-00C/VS-00D decisions are available  
**Primary area:** Ash / DB / Ticket and Delivery Skeletons  
**Depends on:** VS-01C  
**Blocks:** VS-01F, VS-01G, VS-02, VS-08, VS-09A, VS-09B, VS-09C, VS-09D, VS-10, VS-11, VS-15A, VS-15B  
**Source docs:**

```text
docs/fastcheck_sales/SOURCE_DOCS/FastCheck_Sales_Ash_Atlas_Planning_Pack_v0.2.3_HARDENED.md
docs/fastcheck_sales/SOURCE_DOCS/FastCheck_Sales_Vertical_Slice_Roadmap_v1.1.3_HARDENED.md
```

---

> **Normalization note:** This pack was structurally normalized for the `docs/fastcheck_sales/feature_packs/` repo layout. Source-doc references are repo-relative. No semantic scope changes were made in this batch.

---

## 1. Purpose

This pack creates the Ash resource skeletons for the ticket issuance audit layer and delivery attempt audit layer:

```text
FastCheck.Sales.TicketIssue
FastCheck.Sales.DeliveryAttempt
```

This slice gives the Sales domain durable tables for:

```text
issued-ticket audit links
line-item ticket sequencing
existing Attendee linkage placeholders
scanner-status persistence fields
delivery attempt history
Meta/WhatsApp/email delivery audit fields
```

This is still a **skeleton slice**. It must not implement QR rendering, token generation, ticket issuing, Attendee creation, WhatsApp sending, email sending, delivery fallback behavior, scanner mutation, event sync aggregation, Oban workers, admin UI, or customer ticket pages.

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
No channel may bypass Redis inventory, Paystack verification, idempotent ticket issuance, DeliveryAttempt audit, or scanner-safe revocation.
```

---

## 2. Ultimate Outcome

After VS-01D is complete:

```text
The FastCheck.Sales Ash domain registers two additional resources:
  TicketIssue
  DeliveryAttempt

The database has two corresponding tables:
  sales_ticket_issues
  sales_delivery_attempts

TicketIssue belongs to Order and OrderLine.
DeliveryAttempt belongs to Order and TicketIssue.
TicketIssue has the corrected line_item_sequence identity.
TicketIssue.status owns issuance/validity only, not delivery history.
DeliveryAttempt is the source of truth for delivery attempt history.
No ticket issuing, Attendee mutation, WhatsApp sending, QR generation, delivery-token generation, or scanner-visible behavior exists yet.
RED/GREEN tests prove resource skeletons, migrations, indexes, relationships, and forbidden boundaries.
```

---

## 3. Scope

### In scope

```text
Inspect existing Ash, Ecto, Repo, migration, and test conventions.
Create FastCheck.Sales.TicketIssue resource skeleton.
Create FastCheck.Sales.DeliveryAttempt resource skeleton.
Register these resources in FastCheck.Sales.
Create database migrations for the two tables.
Add required fields, identities, and indexes for this slice.
Add basic read/list actions only.
Add relationship declarations to Order and OrderLine where appropriate.
Add relationship declarations from TicketIssue to DeliveryAttempt.
Add skeleton tests for resource registration, migrations, fields, relationships, indexes, and forbidden boundaries.
Add/update slice documentation.
Run format, compile, migration, and test commands.
```

### Out of scope

```text
No Conversation resource.
No TicketDeliveryToken resource unless explicitly accepted as a separate later resource.
No QR rendering.
No QR payload encoding.
No delivery-token generation.
No ticket-code generation.
No Attendee creation.
No FastCheck.Tickets.Issuer implementation.
No ticket issuance orchestration.
No existing scanner logic changes.
No event sync version aggregation.
No WhatsApp/Meta API code.
No email delivery code.
No DeliveryAttempt sending worker.
No resend worker.
No Revocation workflow.
No admin/manual review UI.
No customer ticket page.
No Paystack logic.
No Redis logic.
No Oban workers.
No generic update_status action.
No state-machine workflow actions.
```

---

## 4. Required Pre-Implementation Decisions

The coding agent must read the accepted outputs from VS-00A, VS-00B, VS-00C, VS-00D, VS-01A, VS-01B, and VS-01C before implementation.

### Tenant / organization decision

This slice must follow the accepted tenant model.

Rules:

```text
If multi_tenant or future_multi_tenant_prepared is accepted:
  include organization_id or the approved tenant/owner key on both tables if prior Sales tables use it.
  make sure later policies can scope TicketIssue and DeliveryAttempt by organization/event.

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
TicketIssue.status must use the accepted TicketIssue state vocabulary.
DeliveryAttempt.status must use the accepted DeliveryAttempt state vocabulary.
No transition actions are implemented in VS-01D.
TicketIssue.status must not include delivery attempt states unless the accepted matrix explicitly allows derived summaries.
```

Preferred TicketIssue status set:

```text
pending
issued
revoked
manual_review
```

Preferred DeliveryAttempt status set:

```text
queued
sent
delivered
failed
fallback_required
cancelled
manual_review
```

### Security / PII / token decision

VS-00B must be accepted before this slice.

Rules:

```text
delivery_token_hash stores hashes only, never plaintext tokens.
qr_token_hash stores hashes only, never plaintext QR secrets.
recipient may contain phone/email and must be treated as PII.
provider_error_message may contain provider/customer data and must be treated as restricted support data.
No raw Meta/WhatsApp provider payload storage is introduced in this skeleton unless explicitly approved.
No token, QR secret, phone number, email, provider access code, or raw payload may be logged.
```

### Inventory / payment decision

This slice does not mutate inventory or verify payment.

Rules:

```text
TicketIssue may reference paid orders later, but this skeleton must not issue tickets.
Do not add code that assumes payment success.
Do not create tickets from PaymentAttempt or PaymentEvent in this slice.
Do not consume Redis holds in this slice.
```

### Existing Attendee decision

VS-02 will own Attendee origin protection. VS-09B will own Attendee creation bridge.

Rules for this slice:

```text
TicketIssue may store attendee_id as a nullable external reference.
Do not create a belongs_to Ash relationship to existing Attendee unless the existing project already exposes Attendee as an Ash resource, which this roadmap does not assume.
Do not modify existing Attendee schema/context in VS-01D.
Do not modify scanner behavior in VS-01D.
```

---

## 5. Ash Domain and Resource Details

### Ash domain to update

```text
lib/fastcheck/sales.ex
```

Update the existing `FastCheck.Sales` domain from VS-01A/VS-01B/VS-01C to also register:

```text
FastCheck.Sales.TicketIssue
FastCheck.Sales.DeliveryAttempt
```

Do not register resources from later slices.

### Resources created in this slice

```text
lib/fastcheck/sales/ticket_issue.ex
lib/fastcheck/sales/delivery_attempt.ex
```

### Resources from previous slices that may be referenced

```text
FastCheck.Sales.Order
FastCheck.Sales.OrderLine
FastCheck.Sales.CheckoutSession
FastCheck.Sales.PaymentAttempt
FastCheck.Sales.PaymentEvent
FastCheck.Sales.StateTransition
```

Do not modify previous resources beyond the minimum relationship additions needed by this slice. If relationship additions require touching `Order` or `OrderLine`, keep them declarative only and do not add workflow behavior.

---

## 6. Resource Contract — TicketIssue

### Resource module

```text
lib/fastcheck/sales/ticket_issue.ex
```

### Table

```text
sales_ticket_issues
```

### Purpose

`TicketIssue` records the Sales-side audit link for a ticket that will eventually be issued from a verified order. It does **not** create the existing Attendee row and does **not** generate ticket codes, QR payloads, or delivery tokens in this slice.

### Required fields

```text
id
organization_id              # only if accepted tenant model requires it
sales_order_id
sales_order_line_id
line_item_sequence
attendee_id                  # nullable external Ecto Attendee reference
  # not an Ash relationship unless existing Attendee has been migrated to Ash, which is out of scope
ticket_code                  # nullable until issuance slice/code-generation slice defines creation behavior
qr_token_hash                # nullable, hash only, never plaintext
delivery_token_hash          # nullable, hash only, never plaintext
delivery_token_expires_at
status
scanner_status
last_scanner_sync_version
issued_at
revoked_at
revocation_reason
inserted_at
updated_at
```

### Field conventions

```text
line_item_sequence: integer, starts at 1 per order line, required for idempotent issuance later.
ticket_code: unique when present; do not generate it here.
qr_token_hash: hash only; do not generate it here.
delivery_token_hash: hash only; do not generate it here.
scanner_status: durable status snapshot for later scanner-safe revocation work; do not update scanner here.
last_scanner_sync_version: nullable until VS-10/VS-15A define sync behavior.
revocation_reason: nullable in skeleton; later revoke/manual actions require a reason.
```

### Required relationships

```text
belongs_to :order, FastCheck.Sales.Order
belongs_to :order_line, FastCheck.Sales.OrderLine
has_many :delivery_attempts, FastCheck.Sales.DeliveryAttempt
```

Optional back-reference additions to previous resources:

```text
Order has_many :ticket_issues
OrderLine has_many :ticket_issues
```

Do not add Attendee as an Ash relationship unless explicitly accepted by architecture review.

### Basic actions allowed in this slice

```text
read
get_by_id
list_by_order
list_by_order_line
```

Use the project’s existing Ash action conventions. Keep actions read-only or skeleton-safe.

### Workflow actions forbidden in this slice

```text
create_pending
mark_issued
mark_revoked
mark_manual_review
generate_ticket_code
generate_qr_token
generate_delivery_token
issue_ticket
revoke_ticket
resend_ticket
generic update_status
```

These actions belong to later feature packs after policies, ticket-code generation, issuance orchestration, and revocation/scanner-sync behavior exist.

### Required identities and indexes

```text
unique(ticket_code) where ticket_code is not null
unique(sales_order_line_id, line_item_sequence)
unique(attendee_id) where attendee_id is not null
index(sales_order_id)
index(sales_order_line_id)
index(status)
index(scanner_status)
```

If tenanting is accepted, add tenant-aware indexes as required by the accepted tenant policy.

### Ownership rule

```text
TicketIssue.status owns ticket issuance and validity only.
DeliveryAttempt owns delivery provider history, fallback, resend attempts, and delivery audit.
```

Do **not** put `delivery_queued`, `delivered`, or `delivery_failed` into `TicketIssue.status` unless the accepted state-matrix policy explicitly defines those as derived summaries. The preferred plan keeps delivery history in `DeliveryAttempt`.

---

## 7. Resource Contract — DeliveryAttempt

### Resource module

```text
lib/fastcheck/sales/delivery_attempt.ex
```

### Table

```text
sales_delivery_attempts
```

### Purpose

`DeliveryAttempt` records every attempt to deliver a ticket through WhatsApp, email, admin resend, fallback template, or future delivery channel.

This resource is the **source of truth for delivery audit history**.

### Required fields

```text
id
organization_id              # only if accepted tenant model requires it
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
inserted_at
updated_at
```

### Field conventions

```text
channel: whatsapp, email, admin, system, future channels as accepted.
provider: meta, email_provider, internal, none, or accepted provider value.
recipient: PII; phone/email must be masked in future operator views.
status: constrained DeliveryAttempt state, not arbitrary text.
template_name: Meta template/email template name where applicable.
within_whatsapp_window: boolean snapshot of whether session-message delivery was allowed.
provider_message_id: provider reference when present.
attempt_number: integer sequence per ticket_issue_id/channel or per ticket_issue_id depending accepted policy.
provider_error_message: restricted support field; avoid logging.
failure_reason: normalized internal reason if possible.
fallback_channel: planned fallback path, not execution logic in this slice.
correlation_id: used for tracing worker/provider flows later.
```

### Required relationships

```text
belongs_to :order, FastCheck.Sales.Order
belongs_to :ticket_issue, FastCheck.Sales.TicketIssue
```

Optional back-reference additions to previous/current resources:

```text
Order has_many :delivery_attempts
TicketIssue has_many :delivery_attempts
```

### Basic actions allowed in this slice

```text
read
get_by_id
list_by_order
list_by_ticket_issue
list_by_status
```

Use the project’s existing Ash action conventions. Keep actions read-only or skeleton-safe.

### Workflow actions forbidden in this slice

```text
create_queued
mark_sent
mark_delivered
mark_failed
mark_fallback_required
send_whatsapp
send_email
send_template
resend_ticket
generic update_status
```

These actions belong to later delivery/worker/admin packs after policy, Meta API, ticket page, and DeliveryAttempt behavior are implemented.

### Required indexes

```text
index(sales_order_id, status)
index(ticket_issue_id, status)
index(provider_message_id)
index(channel, status, inserted_at)
index(correlation_id)
```

If tenanting is accepted, add tenant-aware indexes as required by the accepted tenant policy.

### Delivery truth rule

```text
DeliveryAttempt is the source of truth for delivery attempts, provider responses, fallback, resend history, and delivery audit.
TicketIssue may later expose derived delivery summaries for admin convenience, but those summaries must not replace DeliveryAttempt records.
```

---

## 8. Required Migration Contracts

Create one or more explicit migrations following existing project conventions.

Required tables:

```text
sales_ticket_issues
sales_delivery_attempts
```

Required migration behavior:

```text
Use explicit table names.
Use explicit foreign keys to Sales tables where safe and consistent with project conventions.
Use nullable attendee_id as an external reference unless existing Attendee constraints are approved.
Use non-null constraints only where safe at skeleton stage.
Use partial unique indexes for nullable unique fields.
Use timestamps consistent with project conventions.
Do not create unrelated tables.
Do not alter scanner/attendee tables in this slice.
```

Suggested nullable vs required fields:

```text
TicketIssue required at skeleton:
  sales_order_id
  sales_order_line_id
  line_item_sequence
  status

TicketIssue nullable at skeleton:
  attendee_id
  ticket_code
  qr_token_hash
  delivery_token_hash
  delivery_token_expires_at
  scanner_status
  last_scanner_sync_version
  issued_at
  revoked_at
  revocation_reason

DeliveryAttempt required at skeleton:
  sales_order_id
  ticket_issue_id
  channel
  status
  attempt_number

DeliveryAttempt nullable at skeleton:
  provider
  recipient
  template_name
  within_whatsapp_window
  provider_message_id
  provider_error_code
  provider_error_message
  failure_reason
  fallback_channel
  correlation_id
  sent_at
  delivered_at
```

The final nullability must follow accepted project conventions and policy decisions, but do not over-constrain fields that only later slices can populate.

---

## 9. Testing Strategy — RED / GREEN

This is an implementation pack, so tests should be written to fail first where practical, then pass after implementation.

### RED tests must fail before implementation when:

```text
FastCheck.Sales.TicketIssue module is missing.
FastCheck.Sales.DeliveryAttempt module is missing.
FastCheck.Sales does not register TicketIssue and DeliveryAttempt.
sales_ticket_issues table is missing.
sales_delivery_attempts table is missing.
TicketIssue required fields are missing.
DeliveryAttempt required fields are missing.
TicketIssue unique(sales_order_line_id, line_item_sequence) is missing.
TicketIssue unique(ticket_code) partial identity/index is missing.
TicketIssue unique(attendee_id) partial identity/index is missing.
DeliveryAttempt indexes are missing.
TicketIssue does not belong to Order.
TicketIssue does not belong to OrderLine.
DeliveryAttempt does not belong to Order.
DeliveryAttempt does not belong to TicketIssue.
TicketIssue contains delivery-attempt workflow states as primary validity states without an accepted derived-summary rule.
Workflow actions such as issue_ticket, mark_issued, create_queued, mark_sent, send_whatsapp, or generic update_status exist too early.
Existing Attendee, scanner, Paystack, Redis, Meta, WhatsApp, ticket-code, QR, or worker code is modified.
Plaintext token fields are introduced.
PII/provider error fields are logged in tests.
```

### GREEN tests must prove:

```text
mix compile passes.
formatting passes.
migrations create only the intended two tables.
TicketIssue and DeliveryAttempt resources compile with AshPostgres.
FastCheck.Sales registers only intended new resources for this slice.
required fields exist with safe skeleton nullability.
required relationships exist.
required unique identities/indexes exist.
read/list skeleton actions work according to project conventions.
TicketIssue.status represents issuance/validity only.
DeliveryAttempt is modeled as delivery audit source of truth.
no workflow behavior or cross-boundary side effects were added.
no scanner/Attendee/Redis/Paystack/Meta/WhatsApp/Ticket generation code was added.
no plaintext token storage was added.
no PII/raw-provider leakage appears in logs or tests.
```

### Suggested test files

Use project conventions, but target files similar to:

```text
test/fastcheck/sales/ticket_issue_test.exs
test/fastcheck/sales/delivery_attempt_test.exs
test/fastcheck/sales/vs_01d_ticket_and_delivery_resource_skeletons_test.exs
```

### Suggested test groups

```text
resource registration tests
migration/table existence tests
field existence tests
relationship tests
identity/index tests
basic read/list action tests
forbidden action absence tests
forbidden file/path modification tests
PII/token safety tests
```

---

## 10. File Paths

### Expected files to create or update

```text
lib/fastcheck/sales.ex
lib/fastcheck/sales/ticket_issue.ex
lib/fastcheck/sales/delivery_attempt.ex
priv/repo/migrations/*create_sales_ticket_issues*.exs
priv/repo/migrations/*create_sales_delivery_attempts*.exs
test/fastcheck/sales/*ticket_issue*test.exs
test/fastcheck/sales/*delivery_attempt*test.exs
test/fastcheck/sales/*vs_01d*test.exs
docs/fastcheck_sales/slices/VS-01D_TICKET_AND_DELIVERY_RESOURCE_SKELETONS.md
```

### Existing files that may be minimally updated

```text
lib/fastcheck/sales/order.ex
lib/fastcheck/sales/order_line.ex
```

Only update these for declarative relationship additions. No workflow actions.

### Forbidden paths for this slice

```text
lib/fastcheck/sales/conversation.ex
lib/fastcheck/sales/inventory/*
lib/fastcheck/payments/paystack/*
lib/fastcheck/messaging/whatsapp/*
lib/fastcheck/tickets/*
lib/fastcheck/workers/*
lib/fastcheck_web/controllers/*
lib/fastcheck_web/controllers/webhooks/*
lib/fastcheck_web/live/sales/*
existing scanner hot-path files
existing Attendee mutation/reconciliation files
existing Android/mobile API files
```

If a required existing convention forces touching one of these, stop and report the reason before proceeding.

---

## 11. Performance and Scaling Review

### Data layer classification

```text
TicketIssue: cold durable Postgres audit and scanner-link state.
DeliveryAttempt: cold durable Postgres delivery audit.
Derived delivery summaries: future warm/admin cache only, not part of this slice.
Ticket/QR/delivery-token secrets: hash only at rest; generation happens later.
```

### Performance rules

```text
Do not add hot runtime ticket issuing paths in this slice.
Do not query large delivery/ticket tables without indexes.
Do not create dashboard queries in this slice.
Do not create scanner-visible sync behavior in this slice.
Prepare indexes for future admin/support query paths.
Prepare identities for idempotent ticket issuance retries.
```

### Required indexes for future performance

```text
TicketIssue:
  unique(ticket_code) where not null
  unique(sales_order_line_id, line_item_sequence)
  unique(attendee_id) where not null
  index(sales_order_id)
  index(sales_order_line_id)
  index(status)
  index(scanner_status)

DeliveryAttempt:
  index(sales_order_id, status)
  index(ticket_issue_id, status)
  index(provider_message_id)
  index(channel, status, inserted_at)
  index(correlation_id)
```

### Scaling notes

```text
This slice is not on the hot checkout path.
It enables future safe retry behavior under duplicate Oban execution.
It does not yet broadcast PubSub or update scanner/mobile sync state.
Future VS-09 and VS-15A must use these identities to avoid duplicate tickets and scanner-valid revoked tickets.
```

---

## 12. Security Review

### Sensitive fields introduced

```text
recipient
provider_error_message
failure_reason
qr_token_hash
delivery_token_hash
ticket_code
attendee_id
```

### Rules

```text
Never store plaintext delivery tokens.
Never store plaintext QR secrets.
Never log recipient, provider_error_message, QR secrets, delivery tokens, or raw provider payloads.
Do not expose provider_error_message or recipient to operator-level broad lists by default.
Do not add raw Meta/WhatsApp payload fields unless accepted by VS-00B.
Do not implement customer ticket access here.
```

Policy enforcement lands in VS-01F, but this slice must not make that enforcement impossible.

---

## 13. Human Review Checklist

The reviewer must verify:

```text
Only TicketIssue and DeliveryAttempt resources were added.
FastCheck.Sales registers the two new resources.
No Conversation resource was created.
No ticket issuing logic was added.
No Attendee creation or scanner logic was touched.
No QR/token generation was added.
No WhatsApp/Meta/email sending was added.
No Redis/Paystack logic was added.
TicketIssue has line_item_sequence.
TicketIssue has unique(sales_order_line_id, line_item_sequence).
TicketIssue.status is issuance/validity only.
DeliveryAttempt is the delivery audit source of truth.
Required indexes exist.
Partial unique indexes are correct.
PII/token fields are not logged.
Tests prove forbidden boundaries.
```

---

## 14. TOON Coding-Agent Prompt

| Field | Content |
|---|---|
| Task | Create the VS-01D TicketIssue and DeliveryAttempt Ash resource skeletons for FastCheck Sales. |
| Objective | Add durable Sales-side ticket issuance audit and delivery attempt audit tables/resources so later slices can safely implement ticket-code generation, idempotent issuance, DeliveryAttempt history, scanner-safe revocation, and WhatsApp-first ticket delivery without changing scanner/payment/inventory logic in this slice. |
| Output | Create/update `lib/fastcheck/sales.ex`, `lib/fastcheck/sales/ticket_issue.ex`, `lib/fastcheck/sales/delivery_attempt.ex`, the required migrations for `sales_ticket_issues` and `sales_delivery_attempts`, relevant relationship additions to prior Sales resources, tests under `test/fastcheck/sales/`, and `docs/fastcheck_sales/slices/VS-01D_TICKET_AND_DELIVERY_RESOURCE_SKELETONS.md`. |
| Note | Use Ash 3.x and AshPostgres conventions already present in the project. Implement only resource skeletons, migrations, identities, indexes, relationships, timestamps, and basic read/list actions. Do not implement `create_pending`, `mark_issued`, `mark_revoked`, `create_queued`, `mark_sent`, `mark_delivered`, `mark_failed`, `send_whatsapp`, ticket issuance, Attendee creation, QR generation, token generation, scanner mutation, Redis mutation, Paystack logic, Meta/WhatsApp logic, Oban workers, LiveView/admin UI, or generic `update_status`. `TicketIssue.status` must represent issuance/validity only; `DeliveryAttempt` is the source of truth for delivery audit. Required indexes: TicketIssue unique `ticket_code` where not null, unique `sales_order_line_id + line_item_sequence`, unique `attendee_id` where not null, indexes on `sales_order_id`, `sales_order_line_id`, `status`, `scanner_status`; DeliveryAttempt indexes on `sales_order_id + status`, `ticket_issue_id + status`, `provider_message_id`, `channel + status + inserted_at`, `correlation_id`. Store only token hashes, never plaintext tokens or QR secrets. Treat `recipient` and provider error fields as PII/restricted. Respect the accepted tenant model and state vocabulary from VS-00A/VS-00B/VS-00C/VS-00D. Tests must be RED/GREEN and prove resource registration, migrations, fields, relationships, indexes, forbidden actions, forbidden paths, and no PII/token logging. |

---

## 15. Copy-Paste Prompt for Coding Agent

```text
You are implementing FastCheck Sales slice VS-01D — Ticket and Delivery Resource Skeletons.

Read these source docs first:
- FastCheck_Sales_Ash_Atlas_Planning_Pack_v0.2.3_HARDENED.md
- FastCheck_Sales_Vertical_Slice_Roadmap_v1.1.3_HARDENED.md
- accepted outputs from VS-00A, VS-00B, VS-00C, VS-00D, VS-01A, VS-01B, and VS-01C

Goal:
Create only the Ash resource skeletons and DB tables for:
- FastCheck.Sales.TicketIssue
- FastCheck.Sales.DeliveryAttempt

Files expected:
- lib/fastcheck/sales.ex
- lib/fastcheck/sales/ticket_issue.ex
- lib/fastcheck/sales/delivery_attempt.ex
- priv/repo/migrations/*create_sales_ticket_issues*.exs
- priv/repo/migrations/*create_sales_delivery_attempts*.exs
- tests under test/fastcheck/sales/
- docs/fastcheck_sales/slices/VS-01D_TICKET_AND_DELIVERY_RESOURCE_SKELETONS.md

Implement:
- Ash 3.x / AshPostgres resource skeletons
- migrations
- fields
- timestamps
- required identities/indexes
- relationships
- basic read/list actions only
- RED/GREEN tests for resource registration, migration shape, fields, indexes, relationships, and forbidden boundaries

TicketIssue contract:
- table: sales_ticket_issues
- fields: id, tenant key if accepted, sales_order_id, sales_order_line_id, line_item_sequence, attendee_id, ticket_code, qr_token_hash, delivery_token_hash, delivery_token_expires_at, status, scanner_status, last_scanner_sync_version, issued_at, revoked_at, revocation_reason, timestamps
- belongs_to Order
- belongs_to OrderLine
- has_many DeliveryAttempt
- unique ticket_code where not null
- unique sales_order_line_id + line_item_sequence
- unique attendee_id where not null
- indexes on sales_order_id, sales_order_line_id, status, scanner_status
- TicketIssue.status owns issuance/validity only, not delivery history

DeliveryAttempt contract:
- table: sales_delivery_attempts
- fields: id, tenant key if accepted, sales_order_id, ticket_issue_id, channel, provider, recipient, status, template_name, within_whatsapp_window, provider_message_id, attempt_number, provider_error_code, provider_error_message, failure_reason, fallback_channel, correlation_id, sent_at, delivered_at, timestamps
- belongs_to Order
- belongs_to TicketIssue
- indexes on sales_order_id + status, ticket_issue_id + status, provider_message_id, channel + status + inserted_at, correlation_id
- DeliveryAttempt is the source of truth for delivery attempts, provider responses, fallback, resend history, and delivery audit

Do not implement:
- Conversation resource
- TicketDeliveryToken resource unless separately approved
- QR rendering
- ticket-code generation
- delivery-token generation
- Attendee creation
- FastCheck.Tickets.Issuer
- ticket issuance orchestration
- scanner mutation
- event sync aggregation
- WhatsApp/Meta API code
- email sending
- DeliveryAttempt sending workers
- admin/manual review UI
- customer ticket page
- Paystack logic
- Redis logic
- Oban workers
- generic update_status
- workflow transition actions

Security:
- Store only token hashes, never plaintext tokens or QR secrets.
- Treat recipient and provider error fields as PII/restricted.
- Do not log recipient, provider_error_message, QR secrets, delivery tokens, raw provider payloads, or token values.

Testing:
- Write tests that fail before implementation and pass after implementation.
- Tests must prove resource modules exist, Sales domain registration exists, tables exist, fields exist, relationships exist, identities/indexes exist, forbidden workflow actions are absent, forbidden paths are untouched, and PII/token logging does not exist.

Run the project’s normal format, compile, migration, and test commands.
Report any blockers instead of guessing if accepted planning decisions are missing.
```

---

## 16. Success Criteria

This pack is complete when:

```text
TicketIssue resource skeleton exists.
DeliveryAttempt resource skeleton exists.
FastCheck.Sales registers both resources.
sales_ticket_issues migration/table exists.
sales_delivery_attempts migration/table exists.
TicketIssue has line_item_sequence and required unique identities/indexes.
DeliveryAttempt has required audit fields and indexes.
Relationships to Order/OrderLine/TicketIssue are present.
Only basic read/list actions exist.
No workflow actions exist.
No QR/token/code generation exists.
No Attendee/scanner mutation exists.
No Redis/Paystack/Meta/WhatsApp code exists.
No admin/customer UI exists.
Tests prove RED/GREEN behavior.
Documentation for VS-01D exists.
Human review confirms boundary compliance.
```
