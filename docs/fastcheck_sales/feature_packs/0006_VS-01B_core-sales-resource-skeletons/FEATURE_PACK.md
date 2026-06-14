# FastCheck Sales Feature Planning Pack — VS-01B Core Sales Resource Skeletons

**Pack ID:** `0006_VS-01B_core-sales-resource-skeletons`  
**Repository path:** `docs/fastcheck_sales/feature_packs/0006_VS-01B_core-sales-resource-skeletons`  
**Slice:** `VS-01B`  
**Slice name:** Core Sales Resource Skeletons  
**Version:** `v1.0`  
**Date:** 2026-06-12  
**Status:** Ready for implementation only after VS-01A is accepted and VS-00A/VS-00B/VS-00C/VS-00D decisions are available  
**Primary area:** Ash / DB / Core Sales Skeletons  
**Depends on:** VS-01A  
**Blocks:** VS-01C, VS-01F, VS-01G, VS-02, VS-03, VS-05  
**Source docs:**

```text
docs/fastcheck_sales/SOURCE_DOCS/FastCheck_Sales_Ash_Atlas_Planning_Pack_v0.2.3_HARDENED.md
docs/fastcheck_sales/SOURCE_DOCS/FastCheck_Sales_Vertical_Slice_Roadmap_v1.1.3_HARDENED.md
```

---

> **Normalization note:** This pack was structurally normalized for the `docs/fastcheck_sales/feature_packs/` repo layout. Source-doc references are repo-relative. No semantic scope changes were made in this batch.

---

## 1. Purpose

This pack creates the first real Ash Sales resource skeletons:

```text
FastCheck.Sales.TicketOffer
FastCheck.Sales.Order
FastCheck.Sales.OrderLine
FastCheck.Sales.StateTransition
```

This slice gives the Sales domain its durable core tables, resource modules, basic read actions, identities, indexes, and relationships among these four resources.

This is still a **skeleton slice**. It must not implement checkout, Redis inventory, Paystack integration, ticket issuing, WhatsApp flows, admin UI, or scanner behavior.

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
No channel may bypass inventory, payment verification, ticket issuance, delivery audit, or scanner-safe revocation.
```

---

## 2. Ultimate Outcome

After VS-01B is complete:

```text
The FastCheck.Sales Ash domain registers four core resources:
  TicketOffer
  Order
  OrderLine
  StateTransition

The database has four corresponding tables:
  sales_ticket_offers
  sales_orders
  sales_order_lines
  sales_state_transitions

Each resource compiles.
Each resource has required attributes, timestamps, identities, and indexes.
Each resource has basic read/list actions only.
No workflow actions are implemented yet.
No external side effects exist inside resources.
No Redis, Paystack, Meta, ticket issuing, scanner, or admin UI code is added.
RED/GREEN tests prove the resource skeletons, migrations, and forbidden boundaries.
```

---

## 3. Scope

### In scope

```text
Inspect existing Ash, Ecto, Repo, migration, and test conventions.
Create FastCheck.Sales.TicketOffer resource skeleton.
Create FastCheck.Sales.Order resource skeleton.
Create FastCheck.Sales.OrderLine resource skeleton.
Create FastCheck.Sales.StateTransition resource skeleton.
Register these resources in FastCheck.Sales.
Create database migrations for the four tables.
Add required identities and indexes for this slice.
Add basic read/list actions.
Add relationship declarations only among resources created in this slice.
Add skeleton tests for resource registration, migrations, fields, relationships, and forbidden boundaries.
Add/update slice documentation.
Run format, compile, migration, and test commands.
```

### Out of scope

```text
No CheckoutSession resource.
No PaymentAttempt resource.
No PaymentEvent resource.
No TicketIssue resource.
No DeliveryAttempt resource.
No Conversation resource.
No Redis inventory ledger.
No Paystack client, initialization, webhook, or verification.
No Meta Cloud API / WhatsApp client.
No QR generation.
No delivery-token generation.
No Attendee creation.
No scanner changes.
No Android/mobile API changes.
No LiveView/admin UI.
No Oban workers.
No checkout flow.
No public web checkout.
No admin-assisted checkout.
No WhatsApp checkout.
No state machine workflow actions.
No generic update_status action.
No StateTransition append helper yet.
```

---

## 4. Required Pre-Implementation Decisions

The coding agent must read the accepted outputs from VS-00A, VS-00B, VS-00C, VS-00D, and VS-01A before implementation.

### Tenant / organization decision

This slice must not guess the tenant model.

Required decision from prior planning:

```text
single_tenant
multi_tenant
future_multi_tenant_prepared
```

Rules:

```text
If multi_tenant or future_multi_tenant_prepared is accepted:
  include organization_id or the approved tenant/owner key on all four tables.
  include tenant/event-scoped indexes where required.
  document that policy enforcement lands in VS-01F.

If single_tenant is accepted:
  do not add organization_id blindly.
  document that the first release is intentionally single-tenant.
  avoid code that would make later tenant isolation impossible.

If no decision exists:
  stop and report blocker. Do not create migrations.
```

### State machine decision

VS-00A must be accepted before this slice, but VS-01B should not implement the full transition machinery.

Rules:

```text
Order.status must use the accepted state vocabulary.
StateTransition fields must support the accepted audit vocabulary.
No transition actions are implemented in VS-01B.
```

### Security decision

VS-00B must be accepted before this slice.

Rules:

```text
Order buyer fields must follow accepted PII rules.
No raw provider payload fields are created in VS-01B.
No logs should print buyer PII.
No admin/operator field policies are implemented until VS-01F.
```

---

## 5. Ash Domain and Resource Details

### Ash domain to update

```text
lib/fastcheck/sales.ex
```

Update the existing `FastCheck.Sales` domain from VS-01A to register:

```text
FastCheck.Sales.TicketOffer
FastCheck.Sales.Order
FastCheck.Sales.OrderLine
FastCheck.Sales.StateTransition
```

Do not register resources from later slices.

### Resources created in this slice

```text
lib/fastcheck/sales/ticket_offer.ex
lib/fastcheck/sales/order.ex
lib/fastcheck/sales/order_line.ex
lib/fastcheck/sales/state_transition.ex
```

### Resources forbidden in this slice

```text
lib/fastcheck/sales/checkout_session.ex
lib/fastcheck/sales/payment_attempt.ex
lib/fastcheck/sales/payment_event.ex
lib/fastcheck/sales/ticket_issue.ex
lib/fastcheck/sales/delivery_attempt.ex
lib/fastcheck/sales/conversation.ex
```

---

## 6. Resource Contract — TicketOffer

### Module

```text
FastCheck.Sales.TicketOffer
```

### Table

```text
sales_ticket_offers
```

### Required fields

```text
id
organization_id             # only if tenant decision requires it
event_id
name
ticket_type
price_cents
currency
configured_quantity_available
initial_quantity
max_per_order
sales_enabled
sales_channel
starts_at
ends_at
lock_version
archived_at
inserted_at
updated_at
```

### Field rules

```text
price_cents: integer, non-negative
currency: ISO 4217 string, uppercase, usually 3 chars
configured_quantity_available: integer, non-negative
initial_quantity: integer, non-negative
max_per_order: integer, positive
sales_enabled: boolean, default false unless architecture decision says otherwise
sales_channel: constrained string/enum if existing conventions support it
starts_at / ends_at: UTC datetime fields
lock_version: integer optimistic-lock field
archived_at: nullable UTC datetime
```

### Relationships

```text
has_many :order_lines, FastCheck.Sales.OrderLine
has_many :orders, through order_lines, only if Ash conventions and created resources support this cleanly
```

### Basic actions allowed

```text
read
get_by_id
list/read all with safe pagination if existing conventions require it
```

### Actions forbidden in VS-01B

```text
create_offer
update_offer
enable_sales
disable_sales
list_active_for_event
get_available_for_checkout
any cache invalidation action
any Redis availability action
```

Those belong to VS-03 and later slices.

### Indexes / identities for this slice

```text
unique(event_id, name) where archived_at is null
index(event_id, sales_enabled, starts_at, ends_at)
```

If tenanting is accepted, include the approved tenant key in relevant composite indexes.

### Notes

```text
Postgres stores durable configured offer data only.
Redis owns live inventory availability during active sales.
Do not implement live availability in this resource.
Do not treat configured_quantity_available as the flash-sale counter.
```

---

## 7. Resource Contract — Order

### Module

```text
FastCheck.Sales.Order
```

### Table

```text
sales_orders
```

### Required fields

```text
id
organization_id             # only if tenant decision requires it
public_reference
event_id
buyer_name
buyer_phone
buyer_email
source_channel
status
total_amount_cents
currency
whatsapp_conversation_id
idempotency_key
expires_at
paid_at
fulfillment_queued_at
ticket_issued_at
cancelled_at
expired_at
refunded_at
manual_review_reason
last_error_code
last_error_message
lock_version
inserted_at
updated_at
```

### Field rules

```text
public_reference: opaque customer-safe reference, never sequential DB id
buyer_phone: normalized E.164 where possible
buyer_email: normalized lowercase where existing conventions support it
source_channel: web | whatsapp | admin | system | test, or equivalent constrained value
status: accepted Order state vocabulary from VS-00A
total_amount_cents: integer, non-negative
currency: ISO 4217 string, uppercase, usually 3 chars
idempotency_key: nullable string with partial unique identity
*_at fields: nullable UTC datetimes
lock_version: integer optimistic-lock field
```

### Relationships allowed in this slice

```text
has_many :order_lines, FastCheck.Sales.OrderLine
```

### Relationships forbidden until later resources exist

```text
has_many :payment_attempts
has_many :ticket_issues
has_many :delivery_attempts
belongs_to :conversation
```

Add these in later slices when those resources exist. Do not reference non-existent modules.

### Basic actions allowed

```text
read
get_by_id
get_by_public_reference if implemented as safe read only
```

### Actions forbidden in VS-01B

```text
create_draft
confirm_checkout
mark_awaiting_payment
mark_payment_pending
mark_paid_unverified
mark_paid_verified
queue_fulfillment
mark_ticket_issued
mark_partially_issued
mark_manual_review
expire_order
cancel_order
mark_refunded
generic update_status
```

Those belong to later workflow slices.

### Indexes / identities for this slice

```text
unique(public_reference)
unique(idempotency_key) where idempotency_key is not null
index(event_id, status, inserted_at)
index(event_id, source_channel, inserted_at)
index(buyer_phone)
index(expires_at, status)
index(status, fulfillment_queued_at)
```

If tenanting is accepted, include the approved tenant key in relevant composite indexes.

### Notes

```text
Order is the durable money-bearing record, but VS-01B does not implement money workflow.
No payment verification or ticket issuance can happen in this slice.
No customer-facing checkout can happen in this slice.
No broad customer_session reads should be introduced.
```

---

## 8. Resource Contract — OrderLine

### Module

```text
FastCheck.Sales.OrderLine
```

### Table

```text
sales_order_lines
```

### Required fields

```text
id
sales_order_id
ticket_offer_id
line_number
ticket_type
offer_name_snapshot
event_name_snapshot
quantity
unit_amount_cents
total_amount_cents
currency
metadata
inserted_at
updated_at
```

### Field rules

```text
line_number: positive integer unique per sales_order_id
quantity: positive integer
unit_amount_cents: integer, non-negative
total_amount_cents: integer, non-negative
currency: ISO 4217 string, uppercase, usually 3 chars
metadata: map/jsonb
```

### Relationships

```text
belongs_to :order, FastCheck.Sales.Order
belongs_to :ticket_offer, FastCheck.Sales.TicketOffer
```

### Relationships forbidden until later resources exist

```text
has_many :ticket_issues
```

Add this in VS-01D when TicketIssue exists.

### Basic actions allowed

```text
read
get_by_id
list_for_order as read-only if implemented without workflow behavior
```

### Actions forbidden in VS-01B

```text
create_for_order
any price recalculation action
any checkout action
```

### Indexes / identities for this slice

```text
index(sales_order_id)
index(ticket_offer_id)
unique(sales_order_id, line_number)
```

### Notes

```text
OrderLine is a durable price snapshot.
Never recalculate historical price from TicketOffer after order creation.
VS-01B creates the shape only; actual order-line creation belongs to checkout/order workflow slices.
```

---

## 9. Resource Contract — StateTransition

### Module

```text
FastCheck.Sales.StateTransition
```

### Table

```text
sales_state_transitions
```

### Required fields

```text
id
entity_type
entity_id
from_state
to_state
reason
actor_type
actor_id
metadata
correlation_id
request_id
idempotency_key
source
inserted_at
```

### Field rules

```text
entity_type: string matching approved audited entity names
entity_id: uuid/id matching audited entity
from_state: nullable string for initial creation transitions
to_state: string
reason: required later for manual admin/operator transitions; may be nullable at skeleton level only if future action validation enforces it
actor_type: system | admin | operator | customer_session, or equivalent accepted value
actor_id: nullable string/uuid/id depending existing auth conventions
metadata: map/jsonb
correlation_id: nullable string
request_id: nullable string
idempotency_key: nullable string
source: nullable string describing webhook, worker, admin, checkout, whatsapp, etc.
inserted_at: UTC timestamp
```

### Relationships

```text
none required initially
```

### Basic actions allowed

```text
read
list_for_entity as read-only if implemented safely and indexed
list_recent_for_dashboard as read-only only if paginated and indexed
```

### Actions forbidden in VS-01B

```text
record_transition
update
destroy
manual override actions
any action that mutates another resource
```

`record_transition` belongs to VS-01F/VS-09-style action hardening or the dedicated audit pack after transition policy is ready.

### Indexes / identities for this slice

```text
index(entity_type, entity_id, inserted_at)
index(actor_type, actor_id, inserted_at)
index(correlation_id)
```

### Notes

```text
StateTransition is append-only by policy.
VS-01B should not expose update or destroy actions.
Future state-changing slices must append StateTransition rows.
```

---

## 10. Database and Migration Requirements

### Expected tables

```text
sales_ticket_offers
sales_orders
sales_order_lines
sales_state_transitions
```

### Migration rules

```text
Use the existing repo migration conventions.
Prefer AshPostgres codegen/migration workflow if the project uses it.
Use explicit migrations for constraints/indexes that codegen does not fully express.
Do not create tables for later resources.
Do not create triggers, workers, Redis keys, or provider-specific tables.
All money fields must be integer columns, never float/decimal for this slice.
All timestamp fields should follow existing UTC timestamp conventions.
All map/json fields should use the existing Postgres JSONB convention if available.
```

### Required constraints

```text
non-negative amount/quantity constraints where repo style supports DB check constraints
unique and partial unique constraints listed in resource sections
foreign keys from sales_order_lines to sales_orders and sales_ticket_offers
```

### Deferred constraints / later slices

```text
No foreign keys to PaymentAttempt, TicketIssue, DeliveryAttempt, Conversation, or Attendee yet.
No checkout session constraints yet.
No payment provider constraints yet.
No delivery token constraints yet.
```

---

## 11. Required Files / Artifacts

### Expected source files

```text
lib/fastcheck/sales.ex
lib/fastcheck/sales/ticket_offer.ex
lib/fastcheck/sales/order.ex
lib/fastcheck/sales/order_line.ex
lib/fastcheck/sales/state_transition.ex
```

### Expected migration files

Use existing migration naming, but they must create only:

```text
sales_ticket_offers
sales_orders
sales_order_lines
sales_state_transitions
```

### Expected test files

Use repo conventions, but recommended files are:

```text
test/fastcheck/sales/core_resource_skeletons_test.exs
test/fastcheck/sales/core_resource_migrations_test.exs
test/fastcheck/sales/core_resource_boundary_test.exs
```

### Expected documentation file

```text
docs/fastcheck_sales/slices/VS-01B_CORE_SALES_RESOURCE_SKELETONS.md
```

### Files that must not be created

```text
lib/fastcheck/sales/checkout_session.ex
lib/fastcheck/sales/payment_attempt.ex
lib/fastcheck/sales/payment_event.ex
lib/fastcheck/sales/ticket_issue.ex
lib/fastcheck/sales/delivery_attempt.ex
lib/fastcheck/sales/conversation.ex
lib/fastcheck/sales/inventory/*
lib/fastcheck/payments/paystack/*
lib/fastcheck/messaging/whatsapp/*
lib/fastcheck/tickets/*
lib/fastcheck/workers/*sales*
lib/fastcheck_web/live/sales/*
lib/fastcheck_web/controllers/webhooks/paystack_controller.ex
lib/fastcheck_web/controllers/webhooks/whatsapp_controller.ex
```

---

## 12. RED / GREEN Test Plan

The agent must write tests so they fail before implementation and pass after implementation.

### RED tests should fail when

```text
FastCheck.Sales.TicketOffer does not exist.
FastCheck.Sales.Order does not exist.
FastCheck.Sales.OrderLine does not exist.
FastCheck.Sales.StateTransition does not exist.
FastCheck.Sales does not register the four resources.
sales_ticket_offers table does not exist.
sales_orders table does not exist.
sales_order_lines table does not exist.
sales_state_transitions table does not exist.
Required attributes are missing.
Required identities/indexes are missing.
OrderLine foreign keys to Order and TicketOffer are missing.
StateTransition exposes update or destroy actions.
A generic update_status action exists on any resource.
Forbidden later resource modules exist.
Redis, Paystack, Meta, ticket issuing, scanner, or admin UI code is added.
Money fields are implemented as floats.
public_reference is missing a unique identity.
idempotency_key is missing a partial unique identity or documented equivalent.
```

### GREEN tests require

```text
mix compile passes.
mix format --check-formatted passes.
Project migration/test command passes using existing repo conventions.
FastCheck.Sales registers exactly the four VS-01B resources plus no later resources.
Each resource compiles with AshPostgres data layer.
Each expected table exists after migration.
Each required field exists with acceptable type.
Each required identity/index exists or is documented if generated differently by AshPostgres.
TicketOffer <-> OrderLine relationships compile.
Order <-> OrderLine relationships compile.
OrderLine belongs_to Order and TicketOffer.
StateTransition has no update/destroy action.
No external HTTP, Redis, provider, scanner, or worker module was added.
No sales checkout/payment/ticket issuance behavior exists yet.
```

### Suggested test categories

```text
resource registration tests
attribute presence tests
migration/table existence tests
index/identity tests
relationship compile/read tests
forbidden file/module boundary tests
append-only skeleton test for StateTransition
no-workflow-action tests
```

---

## 13. Acceptance Criteria

The slice is accepted only when all are true:

```text
Four required resources exist and compile.
Only four required resources are registered in FastCheck.Sales.
Four required sales tables exist.
Required fields, identities, indexes, and relationships are present.
Only read/list style basic actions exist.
No workflow/state-changing actions are implemented.
No generic update_status action exists.
StateTransition is append-only at skeleton level: no update/destroy actions.
No forbidden resource modules are created.
No Redis/Paystack/Meta/Tickets/Workers/Admin UI/Scanner code is added.
RED/GREEN tests exist and pass after implementation.
VS-01B documentation is added.
Human review confirms no boundary creep.
```

---

## 14. Performance and Scaling Review

### Data layer classification

| Resource | Hot / Warm / Cold | Rule |
|---|---|---|
| TicketOffer | Cold durable config + future warm cache | Postgres stores config; Redis/Cachex display cache added later. |
| Order | Cold durable truth | Indexed by event/status/source/expiry for admin and workers. |
| OrderLine | Cold durable price snapshot | Indexed by order and offer. |
| StateTransition | Cold append-only audit | Indexed by entity and actor for support timelines. |

### Performance rules for this slice

```text
No high-concurrency runtime path is introduced in VS-01B.
No checkout reads should be built yet.
No dashboard queries should be built yet.
Indexes must prepare for future admin and worker query paths.
Do not add expensive preload-heavy helper functions.
Do not load full StateTransition history without pagination in any read helper.
No Redis representation is created yet.
No PubSub broadcasting is added yet.
```

---

## 15. Security Review

```text
Order contains buyer PII fields, but VS-01B must not expose them through controllers, LiveViews, APIs, or logs.
No raw provider payload fields are created in this slice.
No customer-facing tokens are created in this slice.
No policies are fully implemented until VS-01F, but resources must not introduce public/customer access paths.
If tenanting is accepted, tenant fields/indexes must be included now to avoid unsafe future retrofits.
```

---

## 16. TOON Coding-Agent Prompt

| Field | Content |
|---|---|
| Task | Implement VS-01B Core Sales Resource Skeletons for FastCheck Sales. |
| Objective | Create the first durable Ash/Postgres Sales resource skeletons — TicketOffer, Order, OrderLine, and StateTransition — with migrations, identities, indexes, basic reads, relationships among these resources, and RED/GREEN tests, without adding workflow behavior or cross-boundary side effects. |
| Output | Update `lib/fastcheck/sales.ex`; create `lib/fastcheck/sales/ticket_offer.ex`, `lib/fastcheck/sales/order.ex`, `lib/fastcheck/sales/order_line.ex`, and `lib/fastcheck/sales/state_transition.ex`; create migrations for `sales_ticket_offers`, `sales_orders`, `sales_order_lines`, and `sales_state_transitions`; add tests under `test/fastcheck/sales/`; add `docs/fastcheck_sales/slices/VS-01B_CORE_SALES_RESOURCE_SKELETONS.md`. |
| Note | Use Ash 3.x and AshPostgres conventions already established by VS-01A. Create only skeleton resources and basic read/list actions. Do not implement checkout, Paystack, Redis, Meta, WhatsApp, QR, ticket issuance, scanner, workers, admin UI, policies, or workflow actions. Do not create generic `update_status`. Do not create resources from VS-01C/VS-01D/VS-01E. Use integer cents for money, UTC timestamps, JSONB/map fields for metadata, and accepted enum/string vocabularies from VS-00A. Include indexes: `sales_ticket_offers(event_id, sales_enabled, starts_at, ends_at)`, unique active offer name per event, `sales_orders(public_reference)`, partial unique `sales_orders(idempotency_key)`, order status/expiry/source indexes, `sales_order_lines(sales_order_id)`, `sales_order_lines(ticket_offer_id)`, unique `sales_order_lines(sales_order_id, line_number)`, and StateTransition entity/actor/correlation indexes. If tenanting was accepted, include the approved tenant key in relevant tables and indexes. StateTransition must be append-only at skeleton level: no update/destroy actions. Write RED/GREEN tests proving resource registration, table creation, fields, relationships, indexes/identities, and forbidden boundary behavior. |

---

## 17. Copy-Paste Agent Prompt

```text
Implement VS-01B Core Sales Resource Skeletons for the FastCheck Sales project.

Read these source docs first:
- FastCheck_Sales_Ash_Atlas_Planning_Pack_v0.2.3_HARDENED.md
- FastCheck_Sales_Vertical_Slice_Roadmap_v1.1.3_HARDENED.md
- Accepted outputs from VS-00A, VS-00B, VS-00C, VS-00D, and VS-01A

Goal:
Create only the first core Ash/Postgres Sales resource skeletons:
- FastCheck.Sales.TicketOffer
- FastCheck.Sales.Order
- FastCheck.Sales.OrderLine
- FastCheck.Sales.StateTransition

Update:
- lib/fastcheck/sales.ex

Create:
- lib/fastcheck/sales/ticket_offer.ex
- lib/fastcheck/sales/order.ex
- lib/fastcheck/sales/order_line.ex
- lib/fastcheck/sales/state_transition.ex
- migrations for sales_ticket_offers, sales_orders, sales_order_lines, sales_state_transitions
- tests under test/fastcheck/sales/
- docs/fastcheck_sales/slices/VS-01B_CORE_SALES_RESOURCE_SKELETONS.md

Implement only:
- AshPostgres resource skeletons
- required fields
- basic read/list actions
- identities and indexes
- relationships among resources created in this slice
- tests proving resource registration, tables, fields, relationships, indexes, and boundaries

Do not implement:
- CheckoutSession, PaymentAttempt, PaymentEvent, TicketIssue, DeliveryAttempt, Conversation
- Redis inventory
- Paystack
- Meta/WhatsApp
- QR or delivery-token generation
- ticket issuance
- Attendee creation
- scanner changes
- Android/mobile API changes
- admin UI
- Oban workers
- state workflow actions
- generic update_status
- StateTransition append helper

Important rules:
- Use Ash 3.x and AshPostgres conventions.
- Use integer cents for money.
- Use accepted Order status vocabulary from VS-00A, but do not implement transitions.
- Use accepted tenant decision from VS-00B/VS-00D. Stop if no tenant decision exists.
- StateTransition must have no update/destroy actions.
- No resource may call Redis, Paystack, Meta, scanner, or ticket modules.
- No controller, LiveView, worker, provider, or scanner files should be created.

Tests must fail before implementation and pass after implementation.
Run formatting, compile, migrations, and tests using the repo’s conventions.
Report any existing repo convention that prevents exact file names or test names, and adapt minimally.
```

---

## 18. Human Review Checklist

Before accepting this slice, verify:

```text
Only the four intended resources were created.
No later Sales resources were created.
Only the four intended tables were created.
FastCheck.Sales registers exactly the intended resources.
No workflow/state-changing actions slipped in.
No generic update_status action exists.
StateTransition has no update/destroy actions.
Indexes and identities match the planning pack or have documented repo-specific equivalents.
Tenant decision was followed and documented.
PII fields are not exposed through any UI/API/logging path.
No Redis/Paystack/Meta/Ticket/Worker/Scanner/Admin files were added.
Tests prove the skeleton and boundary constraints.
Docs were updated with what changed and what is deliberately deferred.
```

---

## 19. What Success Looks Like

A successful VS-01B is intentionally limited:

```text
The Sales domain has its first durable database shape.
Agents can build VS-01C/VS-01D/VS-01E on real resources instead of vague docs.
No business workflow is active yet.
No payment, inventory, ticket issuance, WhatsApp, or scanner risk is introduced.
The system is still safe because it cannot sell or issue anything yet.
```
