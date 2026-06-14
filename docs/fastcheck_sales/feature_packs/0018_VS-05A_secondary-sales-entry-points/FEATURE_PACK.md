# FastCheck Sales Feature Planning Pack — VS-05A Secondary Sales Entry Points

**Pack ID:** `0018_VS-05A_secondary-sales-entry-points`  
**Slice:** `VS-05A`  
**Slice name:** Secondary Sales Entry Points  
**Version:** `v1.0`  
**Date:** 2026-06-12  
**Repository path:** `docs/fastcheck_sales/feature_packs/0018_VS-05A_secondary-sales-entry-points/`  
**Status:** Implementation planning pack — coding allowed only for selected secondary entrypoint adapters/surfaces  
**Primary area:** Web / Admin / Checkout adapters / Sales channel boundaries / Tests  
**Depends on:** VS-00D, VS-01F, VS-03, VS-05  
**Blocks:** VS-06B checkout-to-Paystack handoff testing, VS-11 ticket-page customer journey testing, VS-12 admin dashboard integration, VS-18/VS-19 WhatsApp flow reuse validation  
**Source docs:**

```text
docs/fastcheck_sales/SOURCE_DOCS/FastCheck_Sales_Ash_Atlas_Planning_Pack_v0.2.3_HARDENED.md
docs/fastcheck_sales/SOURCE_DOCS/FastCheck_Sales_Vertical_Slice_Roadmap_v1.1.3_HARDENED.md
```

---

## 1. Purpose

This pack instructs a coding agent to implement the **secondary non-WhatsApp Sales entrypoints** for FastCheck Sales.

FastCheck Sales is **multi-channel, but WhatsApp is first**:

```text
Primary production customer channel:
  WhatsApp via Meta Cloud API

Secondary supported Sales paths:
  admin-assisted sales
  web checkout sales
  internal pilot sales
```

VS-05A exists so that admin-assisted and web checkout paths can create or start Sales checkout flows through the same approved Sales core from VS-05. These entrypoints must behave as thin channel adapters. They must not invent separate order, payment, inventory, ticket, delivery, or scanner logic.

This slice is not the WhatsApp sales flow. WhatsApp-first sales is implemented later through VS-16, VS-17, VS-18, VS-19, and VS-20. VS-05A must make sure the checkout core can be reused by WhatsApp later.

---

## 2. Ultimate Outcome

After VS-05A is complete:

```text
Admin-assisted sales can start a checkout through the approved Sales checkout core.
Web checkout sales can start a checkout through the approved Sales checkout core if selected/enabled.
Internal pilot checkout can start a controlled checkout through the same core.
All secondary channels set source_channel correctly.
All secondary channels respect TicketOffer availability/configuration rules via VS-05.
All secondary channels respect actor/policy restrictions from VS-01F.
All secondary channels fail closed if the VS-05 checkout core rejects the request.
No secondary channel bypasses Redis ReservationLedger, Paystack verification, ticket issuance, DeliveryAttempt audit, or scanner-safe revocation.
No Paystack transaction initialization is implemented in this slice.
No WhatsApp/Meta API behavior is implemented in this slice.
No ticket issuance or Attendee creation is implemented in this slice.
RED/GREEN tests prove thin-adapter behavior, policy restrictions, source_channel handling, and boundary safety.
```

The goal is not yet end-to-end paid ticket delivery. The goal is to make secondary sales paths call the same checkout spine safely.

---

## 3. Strategic Channel Rules

### Primary channel

```text
whatsapp_first_paid_core
```

WhatsApp is the first and primary production customer channel.

### Secondary channels in this slice

```text
admin_assisted_sales
web_checkout_sales
internal_pilot_sales
```

These are valid secondary Sales paths. They are not throwaway hacks. They must remain compatible with the same Sales core and later Paystack/ticketing flow.

### Non-negotiable rule

```text
Every Sales channel must call the approved checkout core.
No channel may own inventory, payment authority, ticket issuance authority, delivery audit, or scanner validity.
```

### Practical recommendation

Implement admin-assisted and internal-pilot entrypoints first. Implement public web checkout behind an explicit route/feature flag or enabled setting if public web sales are not ready for immediate launch.

Do not delay WhatsApp slices because web checkout exists. Web/admin paths are secondary; WhatsApp remains first.

---

## 4. Scope

### In scope

```text
Add selected secondary entrypoint adapters/surfaces that call FastCheck.Sales.Checkout.start_checkout/3 or the approved VS-05 checkout API.
Add admin-assisted checkout start path if selected.
Add internal pilot checkout start path if selected.
Add minimal web checkout start path if selected.
Set source_channel correctly: admin, web, internal_pilot, or test.
Validate actor permissions before calling checkout.
Use existing TicketOffer read/list behavior for display only.
Render safe validation errors from the checkout core without leaking internals.
Add feature flag/config gate if public web checkout should exist but not be broadly exposed yet.
Add RED/GREEN tests proving all secondary entrypoints use checkout core and do not duplicate logic.
Add tests for authorization, PII/log redaction, and boundary creep.
```

### Out of scope

```text
No WhatsApp/Meta API behavior.
No Meta inbound webhook.
No WhatsApp number-only conversation flow.
No Paystack HTTP client.
No Paystack transaction initialization.
No Paystack payment link creation.
No webhook handling.
No payment verification.
No ticket issuing.
No Attendee creation.
No QR generation.
No delivery token generation.
No customer ticket page.
No scanner hot-path changes.
No Tickera reconciliation changes.
No Redis Lua changes.
No direct Redis mutation.
No duplicate checkout/order/inventory logic outside the VS-05 checkout core.
No admin refund/revocation/manual-review behavior; that belongs to later VS-12/VS-13/VS-15B.
```

---

## 5. Required Pre-Implementation Decisions

The coding agent must read and follow accepted outputs from:

```text
VS-00D MVP Purchase Entry-Point and Launch Scope Decision
VS-01F Ash Policy Foundation
VS-03 Ticket Offer Management
VS-05 Order and Checkout Core
```

### Required VS-00D decisions

VS-05A must know which secondary paths are enabled now:

```text
internal_pilot_sales: yes/no
admin_assisted_sales: yes/no
web_checkout_sales: yes/no
```

If the decision is not recorded, default to:

```text
admin_assisted_sales: yes
internal_pilot_sales: yes
web_checkout_sales: behind feature flag / not public by default
```

Do not implement WhatsApp-first checkout inside this slice.

### Required discovery step

Before changing code, the agent must locate and document actual repository paths for:

```text
FastCheck.Sales.Checkout orchestration module from VS-05
FastCheck.Sales.TicketOffer resource/list actions
FastCheck.Sales.Order and CheckoutSession read helpers
existing admin authentication/authorization pattern
existing Phoenix router structure
existing LiveView/controller patterns
existing feature flag/config pattern, if any
existing form component patterns, if any
existing test factories/support helpers
existing telemetry/logging conventions
```

Do not create duplicate auth, feature-flag, checkout, Repo, Redis, logging, or telemetry abstractions if approved ones already exist.

---

## 6. Domain and Boundary Details

### Ash domain used

```text
FastCheck.Sales
```

### Ash resources used/read

```text
FastCheck.Sales.TicketOffer
FastCheck.Sales.Order
FastCheck.Sales.OrderLine
FastCheck.Sales.CheckoutSession
FastCheck.Sales.StateTransition
```

### Ash resources modified

Prefer no Ash resource modifications unless VS-05A exposes a missing read/action that is clearly adapter-specific and already allowed by policy.

Allowed small changes only:

```text
safe read/list helpers required for entrypoint display
policy refinements required to enforce actor restrictions
non-sensitive calculations for forms/display
```

Forbidden Ash changes:

```text
generic update_status actions
Paystack/payment state transitions
ticket issuance transitions
refund/revocation transitions
Redis mutation inside resources
provider HTTP side effects
```

### Required checkout boundary

All entrypoints must call the approved VS-05 checkout API, preferably:

```text
FastCheck.Sales.Checkout.start_checkout(input, actor, opts)
```

The exact function name may differ if VS-05 created an equivalent approved module. Do not bypass it.

### Preferred implementation files

Use actual repository conventions, but expected files may include:

```text
lib/fastcheck_web/live/sales/admin_checkout_live.ex
lib/fastcheck_web/controllers/sales/checkout_controller.ex
lib/fastcheck_web/controllers/sales/internal_pilot_checkout_controller.ex
lib/fastcheck_web/router.ex
lib/fastcheck_web/live/sales/components/checkout_form_component.ex
lib/fastcheck/sales/secondary_entrypoints.ex
```

A lightweight non-web adapter module is acceptable if the project is not ready for UI yet:

```text
lib/fastcheck/sales/secondary_entrypoints.ex
```

Purpose:

```text
Normalize admin/web/internal-pilot input, enforce channel-specific actor rules, and call the VS-05 checkout core.
```

### Preferred test files

```text
test/fastcheck/sales/secondary_entrypoints_test.exs
test/fastcheck_web/sales/admin_checkout_live_test.exs
test/fastcheck_web/sales/web_checkout_controller_test.exs
test/fastcheck_web/sales/internal_pilot_checkout_test.exs
test/fastcheck_web/sales/secondary_entrypoints_policy_test.exs
test/fastcheck_web/sales/secondary_entrypoints_boundary_test.exs
test/fastcheck_web/sales/secondary_entrypoints_log_redaction_test.exs
```

Use only the test files relevant to the selected secondary paths.

### Forbidden paths for this slice

Do not modify these except for harmless compile fixes caused by approved changes:

```text
lib/fastcheck/payments/paystack/**
lib/fastcheck/messaging/whatsapp/**
lib/fastcheck_web/controllers/webhooks/**
lib/fastcheck/tickets/issuer.ex
lib/fastcheck/tickets/code_generator.ex
lib/fastcheck/tickets/qr_payload.ex
lib/fastcheck/attendees/**
lib/fastcheck/events/**
lib/fastcheck/mobile/**
```

---

## 7. Entry Point Contracts

## 7.1 Admin-assisted sales

Purpose:

```text
Allow an admin or approved operator to create/start a checkout for a customer without WhatsApp.
```

Required behavior:

```text
Actor must be admin or an operator explicitly allowed by policy.
Actor selects event and TicketOffer from allowed scope.
Actor enters buyer details and quantity.
Code calls the VS-05 checkout core.
source_channel must be admin.
Result returns safe order/checkout reference.
If Paystack is not implemented yet, do not produce a Paystack payment URL.
If Paystack is implemented later, VS-06B may attach transaction initialization to the returned checkout/order.
```

Forbidden:

```text
Do not mark payment paid.
Do not issue tickets.
Do not create Attendees.
Do not manually decrement inventory.
Do not bypass max_per_order or sales window unless a later approved override action exists.
Do not expose raw payment/provider fields.
```

## 7.2 Web checkout sales

Purpose:

```text
Allow a public/customer-facing web path to start a checkout using active TicketOffers.
```

Required behavior:

```text
Public web checkout must read only active/sales_enabled offers through approved controlled reads.
Customer submits quantity and buyer details.
Code calls the VS-05 checkout core using customer_session actor or approved public checkout actor.
source_channel must be web.
Errors must be safe and non-sensitive.
If public web checkout is not meant to launch yet, it must be feature-flagged or route-disabled by default.
```

Forbidden:

```text
Do not expose broad Order or CheckoutSession reads to customer_session.
Do not expose disabled/archived offers.
Do not expose raw inventory Redis keys or hold tokens.
Do not show internal errors, stack traces, provider details, or raw payloads.
Do not create Paystack transaction or ticket here.
```

## 7.3 Internal pilot sales

Purpose:

```text
Allow controlled internal test checkout creation for sandbox and launch rehearsal.
```

Required behavior:

```text
Must require system/admin/test actor.
source_channel must be internal_pilot or test.
Must call the VS-05 checkout core.
Must be clearly non-public.
Must be disabled in production unless deliberately configured.
```

Forbidden:

```text
No public access.
No hidden production backdoor.
No bypass of inventory or state transitions.
No fake paid/ticket-issued states.
```

---

## 8. Routing and UI Rules

### Admin-assisted path

Preferred route location:

```text
/admin/sales/checkout/new
```

or match existing admin route conventions.

Rules:

```text
Must use existing admin authentication and authorization.
Must not expose raw provider payloads, Redis internals, or token values.
Must show safe validation errors.
Must not include refund/manual-review operations.
Must not show hidden global order lists unless VS-12 dashboard exists.
```

### Web checkout path

Preferred route location:

```text
/events/:event_id/checkout
/sales/events/:event_id/checkout
```

or match existing public route conventions.

Rules:

```text
Must list only active/sales_enabled offers.
Must not require broad Order read permission.
Must create checkout through the approved checkout core.
Must be feature-flagged if public web checkout is secondary but not launch-ready.
Must avoid client-side-only validation for quantity/price.
Server-side validation remains authoritative.
```

### Internal pilot path

Preferred route/action:

```text
/admin/sales/internal-pilot/checkout
```

or a test/support function if no route is needed.

Rules:

```text
Must never be available to unauthenticated users.
Must be easy to disable in production.
Must be visibly marked internal/pilot in UI or docs.
```

---

## 9. Data and Source Channel Rules

Every call into checkout must include a correct source channel.

Allowed `source_channel` values for this slice:

```text
admin
web
internal_pilot
test
```

Reserved for later:

```text
whatsapp
```

Rules:

```text
Do not use whatsapp in VS-05A except in tests proving it is not handled here.
Do not accept arbitrary source_channel from public input.
Map source_channel server-side based on route/actor.
Persist source_channel on Order through the VS-05 checkout core.
StateTransition metadata may include source_channel and correlation_id.
StateTransition metadata must not include buyer PII, raw tokens, raw Redis values, or provider payloads.
```

---

## 10. Policy and Security Rules

### Actor rules

```text
admin can use admin-assisted checkout.
operator can use admin-assisted checkout only if VS-01F policy explicitly allows it.
customer_session can use web checkout only through controlled public flow.
system/test actor can use internal pilot only in controlled contexts.
unauthenticated users cannot access admin or internal pilot paths.
customer_session cannot broadly read orders, checkout sessions, payment attempts, payment events, ticket issues, delivery attempts, or conversations.
```

### PII rules

Buyer/customer fields are PII:

```text
buyer_name
buyer_phone
buyer_email
phone_e164
recipient
```

Rules:

```text
Do not log PII.
Do not put PII in telemetry metadata.
Do not put PII in StateTransition metadata unless VS-00B explicitly allows a restricted reference.
Do not show PII in public error pages.
Admin/operator forms may display submitted buyer fields only inside authorized flows.
```

### Token/provider rules

```text
No plaintext ticket delivery tokens.
No Paystack authorization_url or access_code in logs.
No raw Paystack/Meta payloads in this slice.
No Redis hold token display to public users.
```

---

## 11. Performance and Scaling Review

### Data layering

```text
Hot live inventory: Redis through ReservationLedger, called only by VS-05 checkout core.
Warm offer display: Cachex/Redis active-offer cache from VS-03 if available.
Cold durable truth: Postgres/Ash orders, order lines, checkout sessions, transitions.
Browser/UI state: form input only; never authoritative for price, quantity, or availability.
```

### Rules

```text
Entry point pages must not scan large Order, PaymentEvent, TicketIssue, or StateTransition tables.
Offer listing must use active-offer indexed/cached paths.
Quantity/price must be validated server-side.
Do not poll inventory repeatedly from LiveView if PubSub/display cache exists.
Do not load large event/offer collections into memory.
Use pagination/search for admin offer selection if event/offer count can grow.
All actual reservation pressure remains in Redis via VS-05 checkout core.
```

Target expectations:

```text
Admin/web entrypoint overhead should be thin compared with checkout core.
No secondary path should add extra DB calls on the hot reservation path beyond required offer/user validation.
No duplicate checkout attempts should bypass VS-05 idempotency behavior.
```

---

## 12. RED / GREEN Test Plan

The coding agent must write or update failing tests before implementation. Tests must become green after implementation.

### RED tests must fail when

```text
Admin-assisted checkout path is missing when admin_assisted_sales is selected.
Web checkout path is missing or disabled incorrectly when web_checkout_sales is selected.
Internal pilot path is public or available without an approved actor.
Any secondary entrypoint creates Order/OrderLine/CheckoutSession directly instead of calling the VS-05 checkout core.
Any secondary entrypoint mutates Redis directly.
Any secondary entrypoint calls Paystack.
Any secondary entrypoint issues tickets or creates Attendee rows.
Any secondary entrypoint touches WhatsApp/Meta modules.
Public web checkout can list disabled/archived/non-active offers.
Public web checkout can broadly read Orders or CheckoutSessions.
source_channel is accepted directly from public user input.
source_channel is missing or wrong on checkout creation.
Admin/operator permissions are too broad.
Unauthenticated user can access admin/internal pilot paths.
Errors/logs expose PII, Redis internals, tokens, provider payloads, stack traces, access codes, or authorization URLs.
Web checkout is publicly enabled when feature flag/config says disabled.
```

### GREEN tests require

```text
Admin-assisted checkout calls the approved checkout core with source_channel admin.
Web checkout calls the approved checkout core with source_channel web.
Internal pilot checkout calls the approved checkout core with source_channel internal_pilot or test.
Actor and policy rules are enforced for each selected path.
Public web checkout only lists active/sales_enabled offers.
Server-side validation rejects invalid quantity or stale/disabled offer through checkout core.
Errors are safe and do not leak internals.
No PII/secrets/tokens/raw payloads are logged.
No direct Redis mutation exists outside checkout core/ReservationLedger.
No Paystack, WhatsApp, ticket issuance, Attendee, scanner, or revocation behavior is added.
Feature flag/config gates public web checkout correctly if required.
Existing VS-05 checkout tests still pass.
Existing scanner tests still pass.
```

### Suggested test names

```text
test "admin-assisted checkout uses approved checkout core"
test "admin-assisted checkout requires approved admin or operator actor"
test "web checkout lists only active sales-enabled offers"
test "web checkout uses customer_session controlled flow without broad order reads"
test "web checkout maps source_channel server-side"
test "internal pilot checkout is not public"
test "secondary entrypoints do not call Paystack"
test "secondary entrypoints do not mutate Redis directly"
test "secondary entrypoints do not touch WhatsApp modules"
test "secondary entrypoint errors do not leak PII or internal tokens"
test "public web checkout respects feature flag"
```

---

## 13. Acceptance Criteria

This slice is Done only when:

```text
Selected secondary sales paths from VS-00D are implemented or explicitly feature-gated.
Admin-assisted checkout path exists if selected.
Web checkout path exists if selected, or is safely feature-flagged if deferred.
Internal pilot path exists only in controlled/admin/test context if selected.
Every secondary path calls the approved VS-05 checkout core.
No secondary path directly creates order/checkout state outside approved actions/core.
No secondary path directly mutates Redis or inventory keys.
source_channel is mapped server-side and persisted correctly.
Actor/policy tests prove admin/operator/customer_session/system restrictions.
Public web flow cannot broadly read orders or checkout sessions.
Safe errors are returned without PII/secrets/tokens/raw payloads.
No Paystack, WhatsApp, ticket issuance, Attendee, scanner, or revocation behavior is added.
Feature flag/config behavior is tested if public web checkout is not launch-ready.
Existing VS-05 checkout tests still pass.
Existing scanner tests still pass.
```

---

## 14. TOON Coding-Agent Prompt

| Field | Content |
|---|---|
| Task | Implement VS-05A Secondary Sales Entry Points for FastCheck Sales. |
| Objective | Add selected admin-assisted, internal-pilot, and/or web checkout entrypoint adapters that use the shared VS-05 Sales checkout core. This enables multi-channel Sales while preserving WhatsApp-first production direction and preventing duplicate business logic. |
| Output | Minimal route/controller/LiveView/service adapter files for selected secondary channels; tests proving each path calls the approved checkout core, maps `source_channel` server-side, enforces actor policies, and does not call Paystack, WhatsApp, ticket issuance, Attendees, scanner, or direct Redis mutation. |
| Note | Use Ash 3.x through the existing `FastCheck.Sales` domain and the VS-05 checkout core only. Do not create duplicate checkout/order/inventory logic. WhatsApp is first and primary but is not implemented in VS-05A. Admin/web/internal-pilot paths are valid secondary channels. Required indexes/cache rules come from VS-03/VS-05; offer display should use active-offer cached/indexed reads. Hot inventory remains Redis via ReservationLedger inside the checkout core. Public web checkout must be feature-flagged if not ready for launch. No PII/tokens/provider payloads/Redis internals in logs or public errors. RED tests first, then GREEN implementation. |

---

## 15. Copy-Paste Agent Prompt

```text
You are implementing FastCheck Sales VS-05A — Secondary Sales Entry Points.

Read these source docs first:
- FastCheck_Sales_Ash_Atlas_Planning_Pack_v0.2.3_HARDENED.md
- FastCheck_Sales_Vertical_Slice_Roadmap_v1.1.3_HARDENED.md
- Feature pack: 0018_VS-05A_secondary-sales-entry-points/FEATURE_PACK.md

Strategic rule:
FastCheck Sales is multi-channel, but WhatsApp is first. VS-05A implements secondary non-WhatsApp entrypoints only. Do not implement WhatsApp here.

Goal:
Implement selected secondary Sales entrypoints — admin-assisted checkout, internal pilot checkout, and/or web checkout — as thin adapters over the approved VS-05 checkout core.

You must:
1. Discover the approved VS-05 checkout API, preferably `FastCheck.Sales.Checkout.start_checkout/3`.
2. Implement only the selected secondary paths from VS-00D.
3. Map `source_channel` server-side as `admin`, `web`, `internal_pilot`, or `test`.
4. Enforce actor/policy rules from VS-01F.
5. Use approved active TicketOffer reads for display/selection.
6. Call the VS-05 checkout core for actual checkout creation.
7. Return safe errors and safe success references.
8. Feature-flag public web checkout if it should exist but not be public yet.
9. Write RED tests first and make them GREEN.

Forbidden:
- Do not implement WhatsApp/Meta API behavior.
- Do not create Meta inbound webhook or conversation flow.
- Do not call Paystack.
- Do not initialize Paystack transactions.
- Do not verify payments.
- Do not issue tickets.
- Do not create Attendee rows.
- Do not touch scanner hot path.
- Do not mutate Redis directly.
- Do not duplicate checkout/order/inventory logic outside the VS-05 checkout core.
- Do not add refund/revocation/manual-review behavior.
- Do not log PII, tokens, provider payloads, authorization URLs, access codes, Redis internals, or stack traces.

Required tests:
- admin-assisted checkout uses approved checkout core
- admin-assisted checkout requires approved admin/operator actor
- web checkout lists only active sales-enabled offers
- web checkout uses customer_session controlled flow without broad Order/CheckoutSession reads
- source_channel is mapped server-side and cannot be spoofed by public input
- internal pilot checkout is not public
- secondary paths do not mutate Redis directly
- secondary paths do not call Paystack
- secondary paths do not touch WhatsApp/Meta modules
- secondary paths do not issue tickets or create Attendees
- public web checkout respects feature flag/config if applicable
- errors/logs do not expose PII or internals
- existing VS-05 checkout tests and scanner tests still pass

After implementation, report:
- selected secondary paths implemented
- files changed
- routes/actions added
- tests added
- commands run
- RED/GREEN result summary
- any unresolved risks or deviations from this pack
```

---

## 16. Human Review Checklist

Before accepting this slice, verify:

```text
WhatsApp-first strategy remains intact.
VS-05A does not hide WhatsApp implementation inside secondary paths.
Every secondary path calls the VS-05 checkout core.
No duplicate checkout/inventory/payment/ticket logic exists.
source_channel is mapped server-side.
Public users cannot spoof source_channel.
Public web checkout cannot broadly read orders or sessions.
Admin/internal pilot routes are protected.
Feature flag/config behavior is correct if web checkout is deferred.
No Paystack, WhatsApp, ticket issuance, Attendee, scanner, or revocation code was added.
PII/log redaction rules are respected.
Existing checkout and scanner tests still pass.
```

---

## 17. Next Slice

```text
VS-06A — Paystack Client Boundary
```

VS-06A creates the Paystack boundary modules without checkout integration. VS-06B later connects Paystack transaction initialization to checkout/order state.
