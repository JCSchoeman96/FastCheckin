# FastCheck Sales Feature Planning Pack — VS-00D MVP Purchase Entry-Point and Launch Scope Decision

**Pack ID:** `0004_VS-00D_mvp-purchase-entry-point-and-launch-scope-decision`  
**Repository path:** `docs/fastcheck_sales/feature_packs/0004_VS-00D_mvp-purchase-entry-point-and-launch-scope-decision/`  
**Slice:** `VS-00D`  
**Slice name:** MVP Purchase Entry-Point and Launch Scope Decision  
**Version:** `v1.0`  
**Date:** 2026-06-12  
**Status:** Ready for planning after VS-00  
**Primary area:** Product / Architecture / Channel Strategy / Docs  
**Depends on:** VS-00  
**Blocks:** VS-01A+, VS-05A, VS-16–VS-20 launch-scope planning, VS-22, VS-23B, VS-23C  
**Source docs:**

```text
docs/fastcheck_sales/SOURCE_DOCS/FastCheck_Sales_Ash_Atlas_Planning_Pack_v0.2.3_HARDENED.md
docs/fastcheck_sales/SOURCE_DOCS/FastCheck_Sales_Vertical_Slice_Roadmap_v1.1.3_HARDENED.md
```

---

## 1. Purpose

This pack forces one explicit product and launch-scope decision before the implementation roadmap starts.

The project direction is:

```text
FastCheck Sales is multi-channel, but WhatsApp is first.

Primary production customer channel:
  WhatsApp via Meta Cloud API

Payment provider:
  Paystack

Ticket/scanner authority:
  FastCheck backend + existing scanner-compatible Attendee path

Secondary supported Sales paths:
  admin-assisted sales
  web checkout sales
  internal pilot sales
```

This is a planning and decision slice only. It must produce documentation that prevents coding agents from building the wrong product shape, such as a generic web checkout platform with WhatsApp bolted on later, or a WhatsApp flow that owns payment/inventory/ticket issuance logic.

The correct product framing is:

```text
WhatsApp is the first and primary production customer sales channel.
Web checkout and admin-assisted sales are valid secondary channels.
All channels must use the same Sales core.
```

---

## 2. Ultimate Outcome

After VS-00D is complete, the project has accepted decisions for:

```text
primary production launch scope
secondary Sales paths included before first production launch
secondary Sales paths deferred until after WhatsApp-first launch
Sales-core bridge MVP behavior
which slices are launch-critical
which slices are bridge/testing-only
what VS-05A must implement
what VS-16 through VS-20 must implement
what VS-22 must prove
what VS-23B / VS-23C must document
channel authority and anti-bypass rules
RED/GREEN documentation tests
future implementation test expectations
```

No implementation code should be written in this slice.

---

## 3. Scope

### In scope

```text
Confirm WhatsApp-first as the primary production customer channel.
Confirm Paystack as the payment provider for Sales checkout.
Confirm web checkout as a valid secondary sales path.
Confirm admin-assisted sales as a valid secondary sales path.
Confirm internal pilot sales as a test/controlled bridge path.
Define selected launch-scope vocabulary.
Define selected Sales-core bridge MVP scope.
Define VS-05A behavior.
Define launch-critical WhatsApp slices.
Define required E2E tests for selected launch scope.
Define runbook split between core and WhatsApp launch runbooks.
Define channel authority and anti-bypass rules.
Define RED/GREEN documentation validation tests.
```

### Out of scope

```text
No Elixir implementation code.
No Ash resource modules.
No database migrations.
No Redis implementation.
No Paystack implementation.
No Meta/WhatsApp implementation.
No web checkout UI.
No admin checkout UI.
No Oban workers.
No scanner changes.
No detailed TOON prompts for later implementation slices.
```

---

## 4. Domain and Ash Details

### Ash domain

```text
FastCheck.Sales
```

### Ash resources referenced but not implemented

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

### Plain modules referenced but not implemented

```text
FastCheck.Sales.Inventory.ReservationLedger
FastCheck.Payments.Paystack.Client
FastCheck.Payments.Paystack.TransactionInitializer
FastCheck.Payments.Paystack.TransactionVerifier
FastCheck.Payments.Paystack.WebhookVerifier
FastCheck.Messaging.WhatsApp.Client
FastCheck.Messaging.WhatsApp.WebhookVerifier
FastCheck.Messaging.WhatsApp.ConversationStateMachine
FastCheck.Tickets.Issuer
FastCheck.Tickets.DeliveryToken
```

### Channel authority rules

```text
WhatsApp is an interface layer.
Web checkout is an interface layer.
Admin-assisted sales is an interface layer.
Internal pilot flow is an interface/testing layer.

No channel owns durable Sales state directly.
No channel owns inventory authority.
No channel owns payment authority.
No channel owns ticket issuance authority.
No channel owns scanner validity.
```

All channels must call approved Sales/Checkout/Payment/Ticketing services that preserve:

```text
Redis inventory reservation
Paystack server-side verification
idempotent ticket issuance
DeliveryAttempt audit
StateTransition audit
scanner-safe revocation
PII/log-redaction policy
```

---

## 5. Required Files / Artifacts

The coding agent should create documentation artifacts only.

Recommended repo paths:

```text
docs/fastcheck_sales/slices/VS-00D_MVP_PURCHASE_ENTRY_POINT_AND_LAUNCH_SCOPE_DECISION.md
docs/fastcheck_sales/product/PRIMARY_CHANNEL_AND_MULTI_CHANNEL_STRATEGY.md
docs/fastcheck_sales/product/SELECTED_LAUNCH_SCOPE.md
docs/fastcheck_sales/product/SALES_CHANNEL_AUTHORITY_MODEL.md
docs/fastcheck_sales/product/SECONDARY_SALES_PATHS.md
docs/fastcheck_sales/product/SALES_CORE_BRIDGE_MVP.md
docs/fastcheck_sales/product/LAUNCH_SCOPE_TEST_REQUIREMENTS.md
docs/fastcheck_sales/product/LAUNCH_SCOPE_RUNBOOK_REQUIREMENTS.md
docs/fastcheck_sales/product/CHANNEL_DECISION_LOG.md
```

If the repo already has a different docs convention, follow the existing convention but keep names explicit and searchable.

---

## 6. Required Decision Format

Every channel/launch decision must include:

```text
decision name
decision value
decision status
rationale
accepted trade-offs
rejected alternatives
required roadmap effect
slices affected
security effect
inventory effect
payment effect
ticket issuance effect
scanner/sync effect
test requirements
runbook requirements
owner/reviewer
```

Required decision statuses:

```text
accepted
rejected
deferred
accepted_as_secondary
accepted_as_testing_bridge
```

Do not leave product-direction decisions as vague narrative.

---

## 7. Primary Channel Decision

The primary production customer sales channel must be recorded as:

```text
whatsapp_first_paid_core
```

Meaning:

```text
Customers buy tickets primarily through WhatsApp.
Meta Cloud API handles inbound/outbound WhatsApp messaging.
Paystack handles payment.
FastCheck Sales handles durable orders, inventory holds, payment verification state, ticket issuance audit, delivery audit, and scanner-compatible attendee creation.
The existing scanner path remains the scanner authority.
```

Required production-launch slices for WhatsApp-first paid core:

```text
VS-16 Meta Cloud API Outbound Client
VS-17 Meta Inbound Webhook and Session State
VS-18 WhatsApp Number-Only Conversation Flow
VS-19 WhatsApp Payment and Ticket Flow
VS-20 WhatsApp Delivery Window Handling
VS-23C Final WhatsApp Launch Runbooks
```

Non-negotiable channel rule:

```text
WhatsApp must not become a separate business workflow.
WhatsApp must call the same Sales core used by web/admin/internal paths.
```

---

## 8. Secondary Sales Path Decisions

VS-00D must explicitly decide which secondary paths are included before the first WhatsApp-first production launch and which are deferred.

### 8.1 Internal pilot sales

Recommended status:

```text
accepted_as_testing_bridge
```

Meaning:

```text
Internal/test/admin-created orders are allowed for validating Sales core, Paystack integration, ticket issuance, scanner acceptance, and support operations before public traffic.
```

Restrictions:

```text
Not a public paid event channel.
Must use same Sales core.
Must use Redis inventory unless explicitly documented as a non-inventory test fixture.
Must use Paystack sandbox/live rules appropriate to environment.
Must not bypass ticket issuance idempotency.
```

### 8.2 Admin-assisted sales

Recommended status:

```text
accepted_as_secondary
```

Meaning:

```text
Operators/admins can create checkout links/orders for customers as a controlled secondary sales path.
```

Required roadmap effect:

```text
VS-05A includes admin-assisted checkout link creation if pulled before launch.
VS-12/VS-13 must provide support visibility and audited manual operations.
Admin actions must use StateTransition audit and PII masking.
```

Restrictions:

```text
Admin-assisted sales must not bypass Redis inventory.
Admin-assisted sales must not mark orders paid manually without an audited manual-review policy.
Admin-assisted sales must not issue tickets directly.
```

### 8.3 Web checkout sales

Recommended status:

```text
accepted_as_secondary
```

Meaning:

```text
Public/customer-facing web checkout can create checkout sessions as a secondary channel after the shared Sales core is stable.
```

Required roadmap effect:

```text
VS-05A includes public web checkout only if explicitly selected for the release.
VS-05A remains secondary to WhatsApp-first production launch unless deliberately pulled forward.
```

Restrictions:

```text
Web checkout must not become the default product direction.
Web checkout must not bypass WhatsApp-first launch planning.
Web checkout must use the same CheckoutSession, PaymentAttempt, TicketIssue, DeliveryAttempt, and revocation paths.
```

---

## 9. Selected Launch Scope Vocabulary

VS-00D must produce a `SELECTED_LAUNCH_SCOPE` document using this vocabulary.

### Primary launch scope

```text
whatsapp_first_paid_core
```

### Secondary sales paths

```text
internal_pilot_sales
admin_assisted_sales
web_checkout_sales
```

### Required selected-launch-scope example

The recommended default is:

```text
primary_launch_scope: whatsapp_first_paid_core
secondary_paths_before_first_launch:
  - internal_pilot_sales
  - admin_assisted_sales
secondary_paths_after_first_launch:
  - web_checkout_sales
```

Alternative accepted configuration:

```text
primary_launch_scope: whatsapp_first_paid_core
secondary_paths_before_first_launch:
  - internal_pilot_sales
  - admin_assisted_sales
  - web_checkout_sales
secondary_paths_after_first_launch: []
```

Rejected default:

```text
primary_launch_scope: web_checkout_sales
```

Reason:

```text
The product direction is WhatsApp-first. Web checkout is supported, but it is not the primary production customer channel unless the business deliberately changes direction in a future decision log.
```

---

## 10. VS-05A Scope Decision

VS-05A must be defined as:

```text
Secondary Sales Entry Points
```

VS-05A may include one or more of:

```text
internal pilot order/checkout creation
admin-assisted checkout link creation
web checkout sales
```

VS-05A must not claim to implement WhatsApp-first checkout by itself.

WhatsApp-first checkout belongs to:

```text
VS-17 Meta Inbound Webhook and Session State
VS-18 WhatsApp Number-Only Conversation Flow
VS-19 WhatsApp Payment and Ticket Flow
VS-20 WhatsApp Delivery Window Handling
```

VS-05A rules:

```text
Must call approved Sales/Checkout services.
Must use ReservationLedger for inventory.
Must use Paystack initialization path.
Must create durable Order/CheckoutSession/PaymentAttempt records.
Must not issue tickets directly.
Must not verify payment directly.
Must not expose raw provider payloads.
Must include channel/source attribution on created orders.
```

---

## 11. Launch-Critical Slice Classification

VS-00D must classify slices into these categories:

```text
sales_core_required
secondary_sales_path_required
whatsapp_launch_required
ops_required
post_launch_optional
```

### Sales core required

```text
VS-00
VS-00A
VS-00B
VS-00C
VS-00D
VS-01A through VS-01G
VS-02
VS-03
VS-04A through VS-04C
VS-05
VS-06A through VS-06C
VS-07A through VS-07C
VS-08
VS-09A through VS-09D
VS-10
VS-11
VS-12
VS-13
VS-14
VS-15A
VS-21A
VS-21B
VS-22
VS-23A
VS-23B
```

### Secondary sales path required if selected before launch

```text
VS-05A
VS-15B if admin refund/revocation operations are included in launch
```

### WhatsApp launch required

```text
VS-16
VS-17
VS-18
VS-19
VS-20
VS-23C
```

### Post-launch optional unless pulled forward

```text
advanced analytics dashboards
bulk messaging
multi-event campaign automation
complex refund-provider automation
web checkout sales if not selected before first WhatsApp launch
```

---

## 12. Channel Data and State Attribution

Every order/checkout/payment/ticket/delivery path must preserve source attribution.

Required future fields or equivalent:

```text
Order.source_channel
Order.whatsapp_conversation_id
CheckoutSession.state_data
PaymentAttempt.provider
PaymentEvent.provider
DeliveryAttempt.channel
DeliveryAttempt.provider
StateTransition.source
StateTransition.correlation_id
```

Allowed `Order.source_channel` values:

```text
whatsapp
web
admin
system
test
```

Rules:

```text
source_channel is for attribution and analytics, not business-rule bypass.
All source channels share the same inventory/payment/issuance/revocation safety rules.
```

---

## 13. Required RED/GREEN Documentation Tests

These are documentation contract tests, not implementation tests.

### RED tests

The VS-00D pack should fail review if any of these are true:

```text
Primary production channel is not explicitly set to whatsapp_first_paid_core.
Secondary sales paths are not explicitly listed.
VS-05A scope is vague or claims to implement WhatsApp-first checkout by itself.
Web checkout is described as the primary default launch direction.
Admin-assisted sales can bypass Redis inventory.
Any channel can bypass Paystack server-side verification.
Any channel can issue tickets directly.
Any channel can bypass DeliveryAttempt audit.
Any channel can bypass scanner-safe revocation.
Selected launch scope does not define VS-22 test impact.
Selected launch scope does not define VS-23B/VS-23C runbook impact.
Launch-critical WhatsApp slices are not listed.
No decision log is created.
Implementation code is added.
```

### GREEN tests

The VS-00D pack passes review only when:

```text
Primary production channel is set to whatsapp_first_paid_core.
Internal pilot, admin-assisted sales, and web checkout are clearly classified.
VS-05A is scoped to secondary sales entry points only.
WhatsApp-first entrypoint is mapped to VS-17, VS-18, VS-19, and VS-20.
All channels are required to use the same Sales core.
All channels are forbidden from bypassing inventory/payment/issuance/delivery/revocation rules.
Selected launch scope controls VS-22 tests.
Selected launch scope controls VS-23B and VS-23C runbooks.
A channel decision log exists.
No code/migrations/resources/scripts/workers are added.
```

---

## 14. Future Implementation Test Expectations

Later implementation slices must convert this decision into tests.

Required future test groups:

```text
orders created from WhatsApp have source_channel = whatsapp
orders created from admin-assisted flow have source_channel = admin
orders created from web checkout have source_channel = web
all source channels use ReservationLedger for inventory
all source channels create PaymentAttempt through the approved Paystack path
all source channels require Paystack server-side verification before ticket issuance
all source channels issue tickets only through Tickets.Issuer
all source channels record StateTransition audit
all ticket delivery/resend flows record DeliveryAttempt
revocation is scanner-visible for tickets from every source channel
PII/log redaction applies to every source channel
VS-22 covers selected launch scope and selected secondary paths
```

---

## 15. Acceptance Criteria

VS-00D is accepted when:

```text
The primary production channel is explicitly documented as WhatsApp-first.
Paystack remains the payment provider and backend verification authority.
FastCheck Sales remains the inventory/order/ticket issuance authority.
Web checkout and admin-assisted sales are allowed secondary paths.
Internal pilot is defined as a testing/controlled bridge path.
VS-05A has a clear non-WhatsApp secondary-channel scope.
VS-16 through VS-20 are marked required for WhatsApp-first production launch.
VS-22 required tests are tied to selected launch scope.
VS-23B and VS-23C runbook requirements are tied to selected launch scope.
A channel decision log exists.
No implementation code was added.
```

---

## 16. Files That Must Not Change

The agent must not modify implementation code in this slice.

Forbidden areas:

```text
lib/
priv/repo/migrations/
assets/
test/
config/ except docs-only references if the repo already requires it
```

Allowed areas:

```text
docs/fastcheck_sales/product/
docs/fastcheck_sales/slices/
docs/fastcheck_sales/decisions/ if this convention exists
```

If the repo has an ADR convention, the agent may add an ADR-style decision record, but only as documentation.

---

## 17. TOON Prompt

| Field | Content |
|---|---|
| Task | Create the VS-00D MVP Purchase Entry-Point and Launch Scope Decision documentation pack. |
| Objective | Lock the product direction before implementation: FastCheck Sales is multi-channel, but WhatsApp via Meta Cloud API is the first and primary production customer sales channel; Paystack is the payment provider; web/admin/internal paths are valid secondary or bridge paths over the same Sales core. |
| Output | Create docs under `docs/fastcheck_sales/product/` and `docs/fastcheck_sales/slices/VS-00D_MVP_PURCHASE_ENTRY_POINT_AND_LAUNCH_SCOPE_DECISION.md`. Include primary channel strategy, selected launch scope, channel authority model, secondary sales paths, Sales-core bridge MVP, launch-scope test requirements, launch-scope runbook requirements, and a channel decision log. |
| Note | Planning only. Do not implement Elixir code, Ash resources, migrations, Redis logic, Paystack logic, Meta/WhatsApp logic, web checkout, admin UI, Oban workers, tests, or scanner changes. Primary production launch scope must be `whatsapp_first_paid_core`. Secondary supported paths are `internal_pilot_sales`, `admin_assisted_sales`, and `web_checkout_sales`. VS-05A is for secondary sales entry points only and must not pretend to implement WhatsApp-first checkout. WhatsApp-first checkout belongs to VS-17, VS-18, VS-19, and VS-20. All channels must use Redis ReservationLedger, Paystack server-side verification, idempotent Tickets.Issuer issuance, DeliveryAttempt audit, StateTransition audit, and scanner-safe revocation. Define RED/GREEN documentation tests and future implementation test expectations. |

---

## 18. Copy-Paste Prompt for Coding Agent

```text
You are working in the FastCheck Sales project.

Create the VS-00D MVP Purchase Entry-Point and Launch Scope Decision documentation pack.

This is a planning-only slice. Do not write Elixir code. Do not add Ash resources. Do not add migrations. Do not implement Redis, Paystack, Meta/WhatsApp, web checkout, admin UI, Oban workers, tests, or scanner changes.

Use these source documents as the authority:
- docs/fastcheck_sales/SOURCE_DOCS/FastCheck_Sales_Ash_Atlas_Planning_Pack_v0.2.3_HARDENED.md
- docs/fastcheck_sales/SOURCE_DOCS/FastCheck_Sales_Vertical_Slice_Roadmap_v1.1.3_HARDENED.md

Create or update these docs, following existing repo docs conventions if present:
- docs/fastcheck_sales/slices/VS-00D_MVP_PURCHASE_ENTRY_POINT_AND_LAUNCH_SCOPE_DECISION.md
- docs/fastcheck_sales/product/PRIMARY_CHANNEL_AND_MULTI_CHANNEL_STRATEGY.md
- docs/fastcheck_sales/product/SELECTED_LAUNCH_SCOPE.md
- docs/fastcheck_sales/product/SALES_CHANNEL_AUTHORITY_MODEL.md
- docs/fastcheck_sales/product/SECONDARY_SALES_PATHS.md
- docs/fastcheck_sales/product/SALES_CORE_BRIDGE_MVP.md
- docs/fastcheck_sales/product/LAUNCH_SCOPE_TEST_REQUIREMENTS.md
- docs/fastcheck_sales/product/LAUNCH_SCOPE_RUNBOOK_REQUIREMENTS.md
- docs/fastcheck_sales/product/CHANNEL_DECISION_LOG.md

Required product direction:
- FastCheck Sales is multi-channel, but WhatsApp is first.
- Primary production customer channel is WhatsApp via Meta Cloud API.
- Payment provider is Paystack.
- Web checkout and admin-assisted sales are valid secondary sales paths.
- Internal pilot sales are allowed as a testing/controlled bridge path.
- All channels must use the same Sales core.

Required launch-scope decision:
- primary_launch_scope: whatsapp_first_paid_core
- secondary paths to decide: internal_pilot_sales, admin_assisted_sales, web_checkout_sales
- recommended default before first WhatsApp launch: internal_pilot_sales and admin_assisted_sales
- recommended web checkout timing: secondary path, after shared Sales core is stable unless explicitly pulled forward

Required channel authority rules:
- WhatsApp is an interface layer, not the payment/inventory/ticket authority.
- Web checkout is an interface layer, not a separate business workflow.
- Admin-assisted sales is an interface layer, not a bypass path.
- Internal pilot flow is a testing/controlled bridge, not public paid launch.
- No channel may bypass Redis ReservationLedger.
- No channel may bypass Paystack server-side verification.
- No channel may issue tickets directly.
- No channel may bypass DeliveryAttempt audit.
- No channel may bypass StateTransition audit.
- No channel may bypass scanner-safe revocation.

Required VS-05A decision:
- VS-05A is Secondary Sales Entry Points.
- VS-05A may include internal pilot order/checkout creation, admin-assisted checkout link creation, and/or web checkout sales.
- VS-05A must not claim to implement WhatsApp-first checkout by itself.
- WhatsApp-first checkout belongs to VS-17, VS-18, VS-19, and VS-20.

Required RED/GREEN documentation tests:
RED if:
- primary production channel is not explicitly whatsapp_first_paid_core
- secondary sales paths are not classified
- VS-05A scope is vague or claims to implement WhatsApp-first checkout
- web checkout becomes the primary default direction
- any channel can bypass inventory/payment/issuance/delivery/revocation rules
- VS-22 test impact is not tied to launch scope
- VS-23B/VS-23C runbook impact is not tied to launch scope
- no decision log is created
- implementation code is added

GREEN if:
- WhatsApp-first production launch is explicit
- secondary paths are classified
- VS-05A is secondary-only
- WhatsApp entrypoint maps to VS-17 through VS-20
- all channels use the same Sales core and safety rules
- selected launch scope controls VS-22 tests and VS-23B/VS-23C runbooks
- decision log exists
- no implementation code is added

Acceptance criteria:
- All required documentation artifacts exist.
- No code/migrations/resources/scripts/workers/tests are added.
- Product direction is unambiguous.
- Future coding agents cannot reasonably build the wrong sales-channel architecture from missing rules.
```

---

## 19. Human Review Checklist

Before marking VS-00D done, confirm:

```text
WhatsApp-first paid core is the primary production launch scope.
Paystack remains the payment provider.
FastCheck backend remains the Sales/payment verification/ticket issuance authority.
Admin-assisted sales is allowed only as a secondary controlled channel.
Web checkout is allowed only as a secondary channel.
Internal pilot is not public launch.
VS-05A is correctly scoped to secondary sales entry points.
VS-17 through VS-20 are required for WhatsApp-first production launch.
All channels share the same inventory/payment/issuance/revocation rules.
No channel bypass is allowed.
VS-22 launch-scope tests are defined.
VS-23B/VS-23C runbook split is defined.
A channel decision log exists.
No implementation code was added.
```

---

## 20. Success Definition

VS-00D succeeds when future agents cannot reasonably misunderstand the product direction.

The correct understanding must be:

```text
FastCheck Sales is multi-channel, but WhatsApp is first.
The first production customer channel is WhatsApp via Meta Cloud API.
Paystack is the payment provider.
Web and admin-assisted sales are valid secondary channels.
Internal pilot is a controlled bridge/testing path.
Every channel uses the same Sales core.
No channel owns inventory, payment verification, ticket issuance, delivery audit, or scanner validity.
```
