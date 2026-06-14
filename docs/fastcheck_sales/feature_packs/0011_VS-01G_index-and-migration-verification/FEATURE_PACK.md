# FastCheck Sales Feature Planning Pack — VS-01G Index and Migration Verification

**Pack ID:** `0011_VS-01G_index-and-migration-verification`  
**Repository path:** `docs/fastcheck_sales/feature_packs/0011_VS-01G_index-and-migration-verification`  
**Slice:** `VS-01G`  
**Slice name:** Index and Migration Verification  
**Version:** `v1.0`  
**Date:** 2026-06-12  
**Status:** Ready for implementation only after VS-01B, VS-01C, VS-01D, VS-01E, VS-01F and planning gates are accepted  
**Primary area:** DB / AshPostgres / Indexes / Migration QA / Tests  
**Depends on:** VS-01B, VS-01C, VS-01D, VS-01E, VS-01F, VS-00A, VS-00B, VS-00C, VS-00D  
**Blocks:** VS-02, VS-03, VS-04A/VS-04B validation, VS-05, VS-07A–VS-07C, VS-09A–VS-09D, VS-12  
**Source docs:**

```text
docs/fastcheck_sales/SOURCE_DOCS/FastCheck_Sales_Ash_Atlas_Planning_Pack_v0.2.3_HARDENED.md
docs/fastcheck_sales/SOURCE_DOCS/FastCheck_Sales_Vertical_Slice_Roadmap_v1.1.3_HARDENED.md
```

---

## 1. Purpose

This pack verifies and hardens the database contract created by the Sales skeleton slices.

It checks the AshPostgres migrations, Ash identities, unique constraints, partial indexes, foreign keys, high-volume query indexes, timestamp fields, enum/state fields, and rollback safety for the current Sales resources:

```text
FastCheck.Sales.TicketOffer
FastCheck.Sales.Order
FastCheck.Sales.OrderLine
FastCheck.Sales.CheckoutSession
FastCheck.Sales.PaymentAttempt
FastCheck.Sales.PaymentEvent
FastCheck.Sales.TicketIssue
FastCheck.Sales.DeliveryAttempt
FastCheck.Sales.Conversation
FastCheck.Sales.StateTransition
```

This slice may add or correct missing migration/index details. It must not add business workflows, provider integrations, Redis mutations, ticket issuing, WhatsApp flows, admin LiveViews, scanner hot-path changes, or customer-facing routes.

Strategic framing remains:

```text
FastCheck Sales is multi-channel, but WhatsApp is first.

Primary production customer channel:
  WhatsApp via Meta Cloud API

Secondary supported Sales paths:
  admin-assisted sales
  web checkout sales
  internal pilot sales

All sales channels share the same durable Sales schema and must use the same safe core.
```

---

## 2. Ultimate Outcome

After VS-01G is complete:

```text
All Sales tables created by VS-01B through VS-01E have verified migrations.
All required unique constraints and indexes exist.
Partial unique indexes exist where required.
Foreign keys and relationship indexes are present.
High-volume admin/dashboard/query paths have indexes.
Expiry and worker-query paths have indexes.
Payment/webhook dedupe paths have indexes.
Ticket issuance idempotency indexes exist.
Tenant/event-scope indexes exist if organization_id is accepted.
Migration rollback/reversibility has been reviewed.
Tests prove missing critical indexes fail RED and pass GREEN.
No workflow/provider/runtime behavior is introduced.
```

This pack is the final database-foundation gate before feature slices start building real business behavior on top of the Sales schema.

---

## 3. Scope

### In scope

```text
Inspect all Sales migrations created in VS-01B through VS-01E.
Inspect all Sales Ash resources and AshPostgres identities.
Add missing indexes, unique indexes, partial indexes, and constraints.
Add or verify foreign keys and relationship indexes.
Add tests or DB assertions proving critical indexes/constraints exist.
Add tests proving uniqueness constraints reject duplicates.
Add tests proving relationship fields are indexed.
Add migration rollback/reversibility notes.
Add documentation for high-volume query paths and index coverage.
Verify tenant/event scoping indexes if organization_id is accepted.
Verify no large dashboard/payment/order/ticket query path is left unindexed.
Run format, compile, migrations, and relevant DB tests.
```

### Out of scope

```text
No new Sales resources.
No new workflow actions.
No checkout flow behavior.
No Redis inventory implementation.
No Paystack client, webhook, or verification behavior.
No Meta/WhatsApp client, webhook, or conversation menu behavior.
No ticket code generation.
No QR rendering.
No delivery token generation.
No attendee creation.
No ticket issuing orchestration.
No event sync aggregation logic.
No admin LiveView dashboard.
No manual review actions.
No scanner hot-path changes.
No Android/mobile API changes.
No generic update_status actions.
```

---

## 4. Required Pre-Implementation Decisions

The coding agent must read and follow the accepted outputs from:

```text
VS-00A State Machine and Failure Policy Finalization
VS-00B Security, PII, and Token Policy Finalization
VS-00C Inventory Recovery and Reconciliation Contract
VS-00D MVP Purchase Entry-Point and Launch Scope Decision
VS-01A Ash Installation and Sales Domain Shell
VS-01B Core Sales Resource Skeletons
VS-01C Checkout and Payment Resource Skeletons
VS-01D Ticket and Delivery Resource Skeletons
VS-01E Conversation Resource Skeleton
VS-01F Ash Policy Foundation
```

### Tenant / organization decision

If the accepted model includes `organization_id` or another owner-scope field, this slice must verify indexes include tenant/event scope where relevant.

Required rule:

```text
Any admin/operator list path must be capable of filtering by organization/event without large table scans.
```

If the accepted model is intentionally single-tenant, document that decision and do not invent fake `organization_id` indexes without a field.

### State-machine decision

Use the accepted state list from VS-00A. This slice verifies the database columns and constraints are compatible with those states. It does not implement transitions.

### Security / raw payload decision

Use the accepted VS-00B decisions for raw provider payloads.

Rules:

```text
Raw payload fields must not be accidentally indexed in a way that encourages broad search over sensitive blobs.
Index provider_reference, provider_event_id, payload_hash, status, and processing_status instead.
```

### Inventory recovery decision

Use VS-00C to verify checkout/inventory query paths.

Rules:

```text
CheckoutSession status/expires_at must be indexed.
Order expires_at/status must be indexed.
TicketIssue scanner_status/status paths must be indexed.
```

---

## 5. Ash Domain and Resource Details

### Domain

```text
lib/fastcheck/sales.ex
FastCheck.Sales
```

### Resources and tables to verify

| Resource | Table |
|---|---|
| `FastCheck.Sales.TicketOffer` | `sales_ticket_offers` |
| `FastCheck.Sales.Order` | `sales_orders` |
| `FastCheck.Sales.OrderLine` | `sales_order_lines` |
| `FastCheck.Sales.CheckoutSession` | `sales_checkout_sessions` |
| `FastCheck.Sales.PaymentAttempt` | `sales_payment_attempts` |
| `FastCheck.Sales.PaymentEvent` | `sales_payment_events` |
| `FastCheck.Sales.TicketIssue` | `sales_ticket_issues` |
| `FastCheck.Sales.DeliveryAttempt` | `sales_delivery_attempts` |
| `FastCheck.Sales.Conversation` | `sales_conversations` |
| `FastCheck.Sales.StateTransition` | `sales_state_transitions` |

### Required relationship integrity

Verify these relationship paths have foreign keys or explicitly documented reasons if a relationship is intentionally non-FK due to legacy boundaries:

```text
sales_order_lines.sales_order_id -> sales_orders.id
sales_order_lines.ticket_offer_id -> sales_ticket_offers.id
sales_checkout_sessions.sales_order_id -> sales_orders.id
sales_payment_attempts.sales_order_id -> sales_orders.id
sales_ticket_issues.sales_order_id -> sales_orders.id
sales_ticket_issues.sales_order_line_id -> sales_order_lines.id
sales_delivery_attempts.sales_order_id -> sales_orders.id
sales_delivery_attempts.ticket_issue_id -> sales_ticket_issues.id
sales_orders.whatsapp_conversation_id -> sales_conversations.id or documented legacy/reference behavior
```

`TicketIssue.attendee_id` references existing Attendees outside Ash. If a foreign key is unsafe because of legacy schema constraints, document the reason and verify an index exists.

`PaymentEvent.provider_reference` may relate to `PaymentAttempt.provider_reference` by provider/reference rather than FK. That is acceptable, but indexes must support the lookup.

`StateTransition.entity_type/entity_id` is polymorphic audit data and does not require FK relationships.

---

## 6. Required Index and Identity Contract

The coding agent must verify these indexes/constraints or add them through explicit migrations.

If tenanting is accepted, add `organization_id` to relevant composite indexes where query paths require tenant/event scope.

### TicketOffer

```text
unique(event_id, name) where archived_at is null
index(event_id, sales_enabled, starts_at, ends_at)
```

Tenant-aware variant if needed:

```text
unique(organization_id, event_id, name) where archived_at is null
index(organization_id, event_id, sales_enabled, starts_at, ends_at)
```

Purpose:

```text
Admin offer management.
Active offer listing.
Cache invalidation lookup by event.
```

### Order

```text
unique(public_reference)
unique(idempotency_key) where idempotency_key is not null
index(event_id, status, inserted_at)
index(event_id, source_channel, inserted_at)
index(buyer_phone)
index(expires_at, status)
index(status, fulfillment_queued_at)
```

Tenant-aware variants where required:

```text
index(organization_id, event_id, status, inserted_at)
index(organization_id, event_id, source_channel, inserted_at)
```

Purpose:

```text
Customer-safe lookup by public_reference.
Duplicate order prevention.
Admin dashboard filtering.
Checkout expiry workers.
Fulfillment queue scanning.
Support lookup by phone.
```

### OrderLine

```text
index(sales_order_id)
index(ticket_offer_id)
unique(sales_order_id, line_number)
```

Purpose:

```text
Order detail loading.
Offer sales reporting.
Stable line numbering for historical price snapshots.
```

### CheckoutSession

```text
unique(sales_order_id)
unique(redis_hold_key) where redis_hold_key is not null
index(status, expires_at)
index(sales_order_id, status)
```

Purpose:

```text
One checkout session per order unless later policy changes.
Redis hold lookup.
Expiry worker query path.
Support lookup by order/status.
```

### PaymentAttempt

```text
unique(provider, provider_reference)
index(sales_order_id, status)
index(provider, status)
index(last_verified_at)
```

Purpose:

```text
Provider transaction idempotency.
Order payment history.
Verification retry dashboard.
Provider/status admin filtering.
```

### PaymentEvent

```text
unique(provider, provider_event_id)
unique(provider, payload_hash) where provider_event_id is null
index(provider_reference)
index(processing_status, inserted_at)
```

Purpose:

```text
Webhook dedupe.
Fallback dedupe when provider_event_id is absent.
Lookup payment attempt by provider_reference.
Worker retry/unmatched event queue.
```

### TicketIssue

```text
unique(ticket_code)
unique(sales_order_line_id, line_item_sequence)
unique(attendee_id) where attendee_id is not null
index(sales_order_id)
index(status)
index(scanner_status)
```

Purpose:

```text
Ticket-code uniqueness.
Exactly one ticket per purchased quantity unit.
Idempotent attendee/ticket linking.
Order ticket history.
Scanner-visible revocation/refund support.
```

### DeliveryAttempt

```text
index(sales_order_id, status)
index(ticket_issue_id, status)
index(provider_message_id)
index(channel, status, inserted_at)
```

Purpose:

```text
Order support view.
Ticket delivery audit timeline.
Provider message lookup.
Delivery failure/retry queue.
```

### Conversation

```text
index(phone_e164)
index(needs_human, last_message_at)
index(state, expires_at)
```

Optional if accepted:

```text
unique(session_key) where session_key is not null
index(wa_id)
```

Purpose:

```text
WhatsApp resume/support lookup.
Human handoff queue.
Conversation expiry cleanup.
```

### StateTransition

```text
index(entity_type, entity_id, inserted_at)
index(actor_type, actor_id, inserted_at)
index(correlation_id)
```

Purpose:

```text
Audit timeline lookup.
Admin/operator action investigation.
Webhook/worker correlation investigation.
```

---

## 7. Migration Review Requirements

### Required migration checks

```text
Every Sales table has id primary key according to project convention.
Every Sales table has inserted_at/updated_at where expected.
StateTransition has inserted_at and no updated_at unless project convention forces it.
All money fields are integer cents, not floats.
All currency fields are strings constrained by validations or resource rules.
All status/state fields are constrained to known values at Ash/resource level or DB level where project convention supports it.
All JSON/map fields use map/jsonb-equivalent columns.
All token fields are hashes only.
No plaintext token columns exist.
Raw payload columns are restricted and not broadly indexed.
All partial unique indexes are actually partial at DB level, not just documented.
All relationship columns have supporting indexes.
Migration rollback/reversibility is documented or explicitly handled.
```

### Required Ash identity checks

For each resource, compare Ash identities to DB unique constraints.

Rules:

```text
Ash identity without a DB unique constraint is not enough.
DB unique constraint without an Ash identity may be acceptable only if documented.
Critical idempotency constraints must exist at DB level.
```

Critical DB-level constraints:

```text
sales_orders.public_reference
sales_orders.idempotency_key where not null
sales_payment_attempts(provider, provider_reference)
sales_payment_events(provider, provider_event_id)
sales_payment_events(provider, payload_hash) where provider_event_id is null
sales_ticket_issues.ticket_code
sales_ticket_issues(sales_order_line_id, line_item_sequence)
sales_ticket_issues.attendee_id where attendee_id is not null
```

---

## 8. Performance and Scaling Review

This slice does not implement runtime logic, but it determines whether future runtime logic can scale.

### Hot / warm / cold data placement

```text
Hot inventory state: Redis, not Postgres.
Warm offer display cache: Cachex/Redis.
Cold durable business truth: Postgres/Ash.
Raw payment/webhook audit: Postgres, restricted access.
Admin dashboards: indexed Postgres queries plus later cached aggregates/materialized views if needed.
Real-time availability: Redis/PubSub, not repeated DB polling.
```

### Required performance gates

```text
No checkout expiry worker may scan all orders or checkout sessions.
No payment webhook worker may scan all payment events.
No ticket issuance worker may scan all ticket issues.
No admin dashboard query may scan large order/payment/ticket tables during peak sales.
No scanner-visible revocation path may depend on unindexed ticket lookup.
No support phone lookup may require broad table scans.
```

### 100k-concurrency posture

This schema verification pack must ensure future high-concurrency paths have indexed durable fallback:

```text
checkout expiry: sales_checkout_sessions(status, expires_at)
order expiry: sales_orders(expires_at, status)
payment dedupe: payment unique provider/reference and provider/event indexes
ticket issuance idempotency: ticket_code and line_item_sequence unique indexes
revocation/scanner visibility: ticket_issue scanner_status/status indexes
admin support lookup: buyer_phone and event/status indexes
```

---

## 9. Required File Outputs

Expected files or equivalent project-convention paths:

```text
priv/repo/migrations/*sales*_*.exs
lib/fastcheck/sales/*.ex
lib/fastcheck/sales.ex

test/fastcheck/sales/*migration*test.exs or equivalent
test/fastcheck/sales/*index*test.exs or equivalent
test/fastcheck/sales/*identity*test.exs or equivalent
test/fastcheck/sales/*vs_01g*test.exs or equivalent

docs/fastcheck_sales/slices/VS-01G_INDEX_AND_MIGRATION_VERIFICATION.md
```

The implementation may update existing Sales migrations if the project is still pre-release and migrations have not been applied outside development.

If migrations are already shared/applied, create new corrective migrations rather than rewriting history.

---

## 10. Forbidden File Outputs

This slice must not create or modify runtime/provider/customer-surface files:

```text
lib/fastcheck/sales/inventory/*
lib/fastcheck/payments/paystack/*
lib/fastcheck/messaging/whatsapp/*
lib/fastcheck/tickets/issuer.ex
lib/fastcheck/tickets/code_generator.ex
lib/fastcheck/tickets/qr_payload.ex
lib/fastcheck/tickets/delivery_token.ex
lib/fastcheck/workers/*
lib/fastcheck_web/controllers/webhooks/*
lib/fastcheck_web/controllers/ticket_delivery_controller.ex
lib/fastcheck_web/live/sales/*
existing scanner hot-path files
existing Attendee mutation/reconciliation files
existing Android/mobile API files
```

Do not add workflow actions to resource files as part of this slice.

---

## 11. RED/GREEN Test Plan

The coding agent must add tests or database assertions that fail before missing constraints/indexes are present and pass after they are added.

### RED tests — must fail before implementation if indexes/constraints are missing

Required RED expectations:

```text
sales_ticket_offers has unique(event_id, name) where archived_at is null.
sales_ticket_offers has index(event_id, sales_enabled, starts_at, ends_at).

sales_orders has unique(public_reference).
sales_orders has partial unique(idempotency_key) where idempotency_key is not null.
sales_orders has index(event_id, status, inserted_at).
sales_orders has index(event_id, source_channel, inserted_at).
sales_orders has index(buyer_phone).
sales_orders has index(expires_at, status).
sales_orders has index(status, fulfillment_queued_at).

sales_order_lines has index(sales_order_id).
sales_order_lines has index(ticket_offer_id).
sales_order_lines has unique(sales_order_id, line_number).

sales_checkout_sessions has unique(sales_order_id).
sales_checkout_sessions has partial unique(redis_hold_key) where redis_hold_key is not null.
sales_checkout_sessions has index(status, expires_at).
sales_checkout_sessions has index(sales_order_id, status).

sales_payment_attempts has unique(provider, provider_reference).
sales_payment_attempts has index(sales_order_id, status).
sales_payment_attempts has index(provider, status).
sales_payment_attempts has index(last_verified_at).

sales_payment_events has unique(provider, provider_event_id).
sales_payment_events has partial unique(provider, payload_hash) where provider_event_id is null.
sales_payment_events has index(provider_reference).
sales_payment_events has index(processing_status, inserted_at).

sales_ticket_issues has unique(ticket_code).
sales_ticket_issues has unique(sales_order_line_id, line_item_sequence).
sales_ticket_issues has partial unique(attendee_id) where attendee_id is not null.
sales_ticket_issues has index(sales_order_id).
sales_ticket_issues has index(status).
sales_ticket_issues has index(scanner_status).

sales_delivery_attempts has index(sales_order_id, status).
sales_delivery_attempts has index(ticket_issue_id, status).
sales_delivery_attempts has index(provider_message_id).
sales_delivery_attempts has index(channel, status, inserted_at).

sales_conversations has index(phone_e164).
sales_conversations has index(needs_human, last_message_at).
sales_conversations has index(state, expires_at).

sales_state_transitions has index(entity_type, entity_id, inserted_at).
sales_state_transitions has index(actor_type, actor_id, inserted_at).
sales_state_transitions has index(correlation_id).
```

Tenant/event RED expectations if tenanting is accepted:

```text
accepted tenant/event-scope indexes exist.
cross-tenant admin/operator query paths have supporting indexes.
```

### Constraint behavior RED tests

Where practical, add actual insert tests proving duplicates are rejected:

```text
duplicate Order.public_reference is rejected.
duplicate Order.idempotency_key when not null is rejected.
multiple null Order.idempotency_key values are allowed if intended by partial unique policy.
duplicate PaymentAttempt(provider, provider_reference) is rejected.
duplicate PaymentEvent(provider, provider_event_id) is rejected.
duplicate PaymentEvent(provider, payload_hash) with provider_event_id null is rejected.
duplicate TicketIssue.ticket_code is rejected.
duplicate TicketIssue(sales_order_line_id, line_item_sequence) is rejected.
duplicate non-null TicketIssue.attendee_id is rejected.
duplicate OrderLine(sales_order_id, line_number) is rejected.
```

### GREEN tests — must pass after implementation

Required GREEN expectations:

```text
mix format passes.
mix compile passes.
Migrations apply cleanly.
Migrations rollback/reversibility is reviewed or tested according to project convention.
All Sales resource modules compile.
Ash identities align with critical DB unique constraints.
All required indexes/constraints exist.
Duplicate insert tests prove critical DB idempotency constraints.
No workflow actions were added.
No provider/Redis/ticket/scanner/Admin UI behavior was added.
```

### Boundary regression tests

Add tests or static checks where practical:

```text
No files under lib/fastcheck/payments/paystack were added.
No files under lib/fastcheck/messaging/whatsapp were added.
No files under lib/fastcheck/sales/inventory were added.
No files under lib/fastcheck/tickets were added.
No files under lib/fastcheck/workers were added.
No webhook controllers were added.
No admin LiveViews were added.
No scanner hot-path files changed.
No generic update_status action exists.
```

---

## 12. Suggested Test Implementation Approach

Use project conventions first. If the project has helper functions for migration/index assertions, reuse them.

If no helper exists, acceptable test strategies include:

```text
Query PostgreSQL system catalogs for indexes and constraints.
Use Ecto SQL sandbox tests to attempt duplicate inserts and assert constraint errors.
Use Ash resource metadata where reliable to verify identities.
Use `mix ecto.migrations` / migration test conventions if the repo already has them.
```

Avoid brittle tests that only match generated migration filenames. Test DB facts instead:

```text
Prefer: “unique index exists on sales_ticket_issues(sales_order_line_id, line_item_sequence)”
Avoid: “migration file contains this exact string” unless no better option exists.
```

---

## 13. Acceptance Criteria

This pack is accepted only if:

```text
All current Sales tables exist.
All required unique constraints exist at DB level.
All required partial unique constraints exist at DB level.
All required query-path indexes exist.
All relationship columns have indexes.
All critical duplicate/idempotency insert tests pass.
Tenant/event indexes are verified if tenanting is accepted.
Migrations apply cleanly from scratch.
Migration correction strategy is documented if prior migrations are already shared.
No workflow/provider/runtime behavior is added.
No forbidden files are touched.
The slice doc `docs/fastcheck_sales/slices/VS-01G_INDEX_AND_MIGRATION_VERIFICATION.md` is created or updated.
```

---

## 14. Implementation Boundaries

### Allowed

```text
Add corrective migrations for indexes/constraints.
Update Ash identities if they do not match DB unique constraints.
Add or correct relationship index definitions.
Add DB/index/identity tests.
Add documentation for migration/index verification.
```

### Forbidden

```text
Do not add checkout actions.
Do not add offer management workflows.
Do not add payment workflows.
Do not add ticket issuance workflows.
Do not add delivery sending workflows.
Do not add conversation menu workflows.
Do not add manual review workflows.
Do not add provider clients.
Do not add Redis code.
Do not add workers.
Do not add web/admin/public routes.
Do not modify scanner hot path.
Do not create generic update_status actions.
```

---

## 15. TOON Coding-Agent Prompt

| Field | Content |
|---|---|
| Task | Verify and harden the VS-01G Sales indexes, constraints, identities, and migrations for all existing FastCheck.Sales skeleton resources. |
| Objective | Make the Sales database foundation safe for later checkout, payment, inventory, ticket issuance, admin, and WhatsApp slices by proving all critical query paths and idempotency constraints exist at DB level. |
| Output | Add/update explicit migrations for missing indexes/constraints; align Ash identities where needed; add DB/index/identity tests under `test/fastcheck/sales/`; add `docs/fastcheck_sales/slices/VS-01G_INDEX_AND_MIGRATION_VERIFICATION.md`. |
| Note | Use Ash 3.x and AshPostgres conventions. Do not add business workflow actions, Paystack/Meta clients, Redis logic, Oban workers, ticket issuance, QR rendering, Attendee/scanner changes, LiveViews, controllers, public APIs, or generic `update_status`. Required critical constraints include order public reference/idempotency, provider/reference dedupe, webhook dedupe, ticket code uniqueness, ticket issue line-item sequence uniqueness, attendee id partial uniqueness, checkout expiry indexes, payment retry indexes, delivery attempt indexes, conversation handoff/expiry indexes, and state transition audit indexes. If migrations have already been applied outside development, add corrective migrations instead of rewriting history. If tenant/event isolation is accepted, add or verify indexed scope paths. RED/GREEN tests must prove missing indexes/constraints fail and corrected DB facts pass. |

---

## 16. Copy-Paste Prompt for Coding Agent

```text
You are implementing FastCheck Sales slice VS-01G — Index and Migration Verification.

Use Ash 3.x and AshPostgres. Work only on the existing FastCheck.Sales skeleton resources created by VS-01B through VS-01E and protected by VS-01F.

Goal:
Verify and harden all Sales migrations, DB constraints, Ash identities, partial indexes, relationship indexes, and high-volume query-path indexes.

Resources/tables:
- FastCheck.Sales.TicketOffer -> sales_ticket_offers
- FastCheck.Sales.Order -> sales_orders
- FastCheck.Sales.OrderLine -> sales_order_lines
- FastCheck.Sales.CheckoutSession -> sales_checkout_sessions
- FastCheck.Sales.PaymentAttempt -> sales_payment_attempts
- FastCheck.Sales.PaymentEvent -> sales_payment_events
- FastCheck.Sales.TicketIssue -> sales_ticket_issues
- FastCheck.Sales.DeliveryAttempt -> sales_delivery_attempts
- FastCheck.Sales.Conversation -> sales_conversations
- FastCheck.Sales.StateTransition -> sales_state_transitions

Required:
- Verify/create all required indexes and unique constraints from the VS-01G feature pack.
- Ensure critical idempotency constraints exist at DB level, not only in Ash.
- Add tests that fail if indexes/constraints are missing and pass after fixes.
- Add duplicate insert tests for public_reference, idempotency_key, provider/reference, webhook dedupe, ticket_code, line_item_sequence, attendee_id, and order line number where practical.
- Align Ash identities with DB-level unique constraints where appropriate.
- Verify tenant/event-scope indexes if organization_id or equivalent is accepted.
- Create/update docs/fastcheck_sales/slices/VS-01G_INDEX_AND_MIGRATION_VERIFICATION.md.

Forbidden:
- Do not add checkout workflows.
- Do not add TicketOffer management actions.
- Do not add Paystack HTTP/client/webhook/verification behavior.
- Do not add Redis reservation/session/rate-limit behavior.
- Do not add Meta/WhatsApp client/webhook/menu behavior.
- Do not add ticket issuance, QR rendering, Attendee creation, scanner/mobile API changes, Oban workers, admin LiveViews, or public/customer APIs.
- Do not add generic update_status actions.

Migration rule:
- If the repo is still pre-release and migrations are not shared/applied, updating existing Sales migrations is acceptable.
- If migrations are already shared/applied, create corrective migrations instead of rewriting history.

Run:
- mix format
- mix compile
- migrations from scratch according to project convention
- relevant Sales DB/index/identity tests
- existing scanner/runtime regression tests if project convention requires proof

Report:
- files changed
- migrations added/updated
- indexes/constraints verified
- tests added
- any tenant/event isolation blocker
- confirmation that no forbidden boundary files were changed
```

---

## 17. Human Review Checklist

Reviewer must verify:

```text
Every current Sales table exists.
Every required unique constraint exists at DB level.
Every required partial unique index exists at DB level.
Every required high-volume query-path index exists.
Every relationship column has an index.
Ash identities align with critical DB uniqueness.
Duplicate insert tests prove critical idempotency constraints.
Checkout expiry and order expiry query paths are indexed.
Webhook dedupe and provider-reference lookup paths are indexed.
Ticket issuance idempotency paths are indexed.
Revocation/scanner_status query paths are indexed.
Conversation handoff/expiry query paths are indexed.
StateTransition audit query paths are indexed.
Tenant/event indexes exist if required by accepted model.
No workflow actions were introduced.
No Paystack, Meta, Redis, ticket issuance, scanner, Oban, LiveView, controller, or public API behavior was introduced.
Migration rewrite/corrective strategy is appropriate for repo state.
```

---

## 18. Next Slice

After VS-01G is accepted, the next roadmap slice is:

```text
VS-02 — Attendee Origin Protection
```

VS-02 must protect FastCheck-sales-created attendees from Tickera reconciliation before real ticket issuance work is allowed.
