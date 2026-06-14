# FastCheck Sales Feature Planning Pack — VS-01A Ash Installation and Sales Domain Shell

**Pack ID:** `0005_VS-01A_ash-installation-and-sales-domain-shell`  
**Repository path:** `docs/fastcheck_sales/feature_packs/0005_VS-01A_ash-installation-and-sales-domain-shell/`  
**Slice:** `VS-01A`  
**Slice name:** Ash Installation and Sales Domain Shell  
**Version:** `v1.0`  
**Date:** 2026-06-12  
**Status:** Ready for implementation only after VS-00A, VS-00B, VS-00C, and VS-00D are accepted  
**Primary area:** Ash / Config / Boundary Shell  
**Depends on:** VS-00A, VS-00B, VS-00C, VS-00D  
**Blocks:** VS-01B, VS-01C, VS-01D, VS-01E, VS-01F, VS-01G  
**Source docs:**

```text
docs/fastcheck_sales/SOURCE_DOCS/FastCheck_Sales_Ash_Atlas_Planning_Pack_v0.2.3_HARDENED.md
docs/fastcheck_sales/SOURCE_DOCS/FastCheck_Sales_Vertical_Slice_Roadmap_v1.1.3_HARDENED.md
```

---

## 1. Purpose

This pack installs and registers the **empty Ash Sales domain shell** for FastCheck Sales.

This is the first implementation slice after the planning-hardening gates. It creates the technical boundary for future Ash resources, but it must not create business resources, migrations, checkout behavior, payment behavior, Redis logic, ticket issuance, WhatsApp logic, admin UI, or scanner changes.

The strategic product direction remains:

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

This slice only prepares the Ash boundary that later slices will fill.

---

## 2. Ultimate Outcome

After VS-01A is complete:

```text
Ash 3.x and AshPostgres are installed in the project.
FastCheck.Sales exists as the Ash domain module.
FastCheck.Sales is registered in application config.
The Sales domain contains no Ash resources yet.
A boundary document exists explaining what VS-01A added and what it must not own.
A minimal test proves the Sales domain shell compiles and has no resources.
Existing scanner/check-in/mobile paths remain untouched.
No database migrations are created.
No business resource modules are created.
```

This slice is deliberately boring. That is the point. The first implementation step must create a safe shell, not sneak in business behavior.

---

## 3. Scope

### In scope

```text
Inspect existing project structure and naming conventions.
Add Ash 3.x dependency if not already present.
Add AshPostgres dependency if not already present.
Register FastCheck.Sales as an Ash domain in config.
Create lib/fastcheck/sales.ex.
Add a minimal domain-shell test.
Add/update a short boundary document for VS-01A.
Run formatting and tests.
Prove existing scanner tests still pass or clearly report if scanner test commands are unavailable.
```

### Out of scope

```text
No Ash resources.
No sales_* database tables.
No database migrations.
No TicketOffer resource.
No Order resource.
No OrderLine resource.
No CheckoutSession resource.
No PaymentAttempt resource.
No PaymentEvent resource.
No TicketIssue resource.
No DeliveryAttempt resource.
No Conversation resource.
No StateTransition resource.
No Redis calls or Redis scripts.
No Paystack calls.
No Meta/WhatsApp calls.
No QR or delivery-token implementation.
No Attendee mutation.
No scanner logic changes.
No Android/mobile API changes.
No LiveView/admin UI.
No Oban workers.
No state transition actions.
No generic update_status actions.
```

---

## 4. Domain and Ash Details

### Ash domain to create

```text
FastCheck.Sales
```

### Required file

```text
lib/fastcheck/sales.ex
```

### Required domain behavior

```text
Use Ash 3.x domain conventions.
Register the domain in the application configuration.
Keep the resources list empty in this slice.
Do not reference not-yet-created Sales resource modules.
Do not use AshPostgres data layer in the domain shell itself.
Do not add resource registry entries until later VS-01B+ slices create those resources.
```

### Ash resources referenced by architecture, but not created in this slice

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

### Plain modules referenced by architecture, but not created in this slice

```text
FastCheck.Sales.Inventory.ReservationLedger
FastCheck.Sales.Inventory.RedisScripts
FastCheck.Payments.Paystack.Client
FastCheck.Payments.Paystack.TransactionInitializer
FastCheck.Payments.Paystack.TransactionVerifier
FastCheck.Payments.Paystack.WebhookVerifier
FastCheck.Messaging.WhatsApp.Client
FastCheck.Messaging.WhatsApp.WebhookVerifier
FastCheck.Messaging.WhatsApp.ConversationStateMachine
FastCheck.Tickets.CodeGenerator
FastCheck.Tickets.QrPayload
FastCheck.Tickets.DeliveryToken
FastCheck.Tickets.Issuer
```

---

## 5. Required Files / Artifacts

The coding agent should create or update only the following kinds of files.

### Expected source/config files

```text
mix.exs
mix.lock
config/config.exs or the existing equivalent application config file
lib/fastcheck/sales.ex
test/fastcheck/sales/domain_shell_test.exs
```

### Expected documentation file

```text
docs/fastcheck_sales/slices/VS-01A_ASH_INSTALLATION_AND_SALES_DOMAIN_SHELL.md
```

If the repository already has a different docs convention, follow the existing convention, but keep the filename explicit and searchable.

### Files that must not be created in this slice

```text
lib/fastcheck/sales/ticket_offer.ex
lib/fastcheck/sales/order.ex
lib/fastcheck/sales/order_line.ex
lib/fastcheck/sales/checkout_session.ex
lib/fastcheck/sales/payment_attempt.ex
lib/fastcheck/sales/payment_event.ex
lib/fastcheck/sales/ticket_issue.ex
lib/fastcheck/sales/delivery_attempt.ex
lib/fastcheck/sales/conversation.ex
lib/fastcheck/sales/state_transition.ex
priv/repo/migrations/*sales*.exs
lib/fastcheck/sales/inventory/*
lib/fastcheck/payments/paystack/*
lib/fastcheck/messaging/whatsapp/*
lib/fastcheck/tickets/*
lib/fastcheck/workers/*sales*
```

---

## 6. Dependency Rules

### Required dependencies

```text
ash
ash_postgres
```

Rules:

```text
Use Ash 3.x.
Use an AshPostgres version compatible with the selected Ash 3.x version.
Follow existing dependency style in mix.exs.
Do not upgrade unrelated dependencies.
Do not introduce AshPhoenix unless the repo already uses it or a later UI slice explicitly requires it.
Do not introduce Absinthe/GraphQL or JSON API packages in this slice.
Do not introduce provider SDKs in this slice.
```

### Configuration rule

Register the Sales domain in the application config using the project’s existing OTP app name and Ash 3.x conventions.

The domain registration must include:

```text
FastCheck.Sales
```

It must not include resources that do not exist yet.

---

## 7. Boundary Rules

### Ash boundary

```text
Ash owns durable Sales business state in later slices.
This slice only creates the domain shell.
No durable Sales business state exists yet.
```

### Non-Ash boundary

This slice must not change:

```text
existing scanner/check-in logic
existing attendee Ecto schema/context
existing event Ecto schema/context
Tickera sync/reconciliation logic
Android mobile API
Redis inventory logic
Paystack HTTP client/verifier
Meta Cloud API HTTP client/verifier
QR rendering/token encoding
Oban worker orchestration
```

### Channel boundary

This slice must not create a sales channel.

```text
No WhatsApp entrypoint.
No web checkout entrypoint.
No admin-assisted sales entrypoint.
No internal pilot sales entrypoint.
```

The channel strategy is already decided by VS-00D, but channel implementation starts later.

---

## 8. RED / GREEN Test Plan

This slice must use a RED/GREEN workflow.

### RED tests — write first

Create tests that initially fail before the Ash domain shell exists.

Recommended test file:

```text
test/fastcheck/sales/domain_shell_test.exs
```

The RED tests should assert:

```text
FastCheck.Sales module exists.
FastCheck.Sales is a valid Ash domain.
FastCheck.Sales has zero registered resources in VS-01A.
The application config includes FastCheck.Sales in the Ash domain registration.
No Sales resource modules are available yet.
No sales_* migrations exist yet.
```

Expected RED result before implementation:

```text
The test fails because FastCheck.Sales does not exist or is not registered.
```

### GREEN tests — pass after implementation

The GREEN state requires:

```text
mix deps.get succeeds.
mix compile succeeds.
FastCheck.Sales compiles as an Ash domain.
FastCheck.Sales is registered in application config.
The Sales domain has no resources.
No sales_* migrations exist.
No forbidden resource files are created.
The new domain-shell test passes.
Existing scanner/check-in tests pass or are explicitly reported if no targeted test command exists.
```

### Suggested verification commands

The coding agent should adapt commands to the existing project, but should attempt:

```text
mix deps.get
mix format --check-formatted
mix compile
mix test test/fastcheck/sales/domain_shell_test.exs
mix test
```

If full `mix test` is too slow or the repo has known environment requirements, the agent must report exactly which tests were run and why any were skipped.

---

## 9. Acceptance Criteria

This slice is accepted only if all of these are true:

```text
Ash 3.x dependency is present.
AshPostgres dependency is present.
FastCheck.Sales domain module exists.
FastCheck.Sales is registered in config.
FastCheck.Sales has zero registered resources.
No Sales business resource modules were created.
No sales_* database migrations were created.
No Redis, Paystack, Meta, QR, Attendee, scanner, mobile, LiveView, or Oban logic was added.
A domain-shell test exists and passes.
The VS-01A boundary document exists.
Formatting passes.
Compilation passes.
Existing tests pass or any failures are documented with exact command output and clear cause.
```

---

## 10. Failure Modes to Guard Against

| Failure mode | Why it is dangerous | Required prevention |
|---|---|---|
| Agent creates Sales resources early | Breaks slice boundaries and skips state/policy hardening | Tests and review must assert zero resources |
| Agent creates migrations early | Locks database shape before field/index contracts are ready | No `sales_*` migrations in VS-01A |
| Agent changes scanner code | Risks breaking existing event-day runtime | Scanner files must remain untouched |
| Agent adds Paystack/Meta code | Provider boundary slices are later | No provider clients in this slice |
| Agent adds AshPhoenix/API packages | Expands scope into UI/API prematurely | Only Ash/AshPostgres unless already required |
| Agent upgrades unrelated deps | Creates avoidable regression risk | Only required dependency changes |
| Agent registers non-existent resources | Compile/runtime failures | Domain resource list must stay empty |
| Agent uses broad config changes | May affect existing app behavior | Minimal config registration only |

---

## 11. Performance and Scaling Review

This slice does not add runtime Sales traffic, but it still sets architectural precedent.

Required review answers:

```text
Hot data: none added in this slice.
Warm data: none added in this slice.
Cold data: none added in this slice.
Redis representation: none added in this slice.
Postgres migrations: none added in this slice.
PubSub broadcasting: none added in this slice.
Cache invalidation: none added in this slice.
High-concurrency write path: none added in this slice.
```

Performance rule:

```text
Do not add runtime paths that could affect checkout, scanner, attendee sync, or mobile API performance.
```

---

## 12. Security Review

This slice must not introduce new PII storage, tokens, raw payload storage, or provider credentials.

Required review answers:

```text
No PII fields are added.
No customer-facing tokens are added.
No Paystack secrets are added.
No Meta secrets are added.
No raw provider payloads are stored.
No logs containing PII or secrets are added.
No admin/operator access paths are added.
```

---

## 13. TOON Coding-Agent Prompt

| Field | Content |
|---|---|
| Task | Install and register the empty `FastCheck.Sales` Ash domain shell for VS-01A. |
| Objective | Establish the Ash 3.x Sales domain boundary without creating business resources, migrations, checkout behavior, payment behavior, Redis behavior, ticket issuance, WhatsApp behavior, or scanner changes. |
| Output | Update `mix.exs`/`mix.lock` with Ash 3.x and AshPostgres; register `FastCheck.Sales` in config; create `lib/fastcheck/sales.ex`; create `test/fastcheck/sales/domain_shell_test.exs`; create `docs/fastcheck_sales/slices/VS-01A_ASH_INSTALLATION_AND_SALES_DOMAIN_SHELL.md`; run formatting, compile, targeted tests, and existing test checks. |
| Note | Use Ash 3.x. Follow existing project dependency/config style. Keep `FastCheck.Sales` resource list empty. Do not create Sales resource modules or migrations. Do not touch scanner, Attendees, Events, Tickera sync, Android/mobile API, Redis, Paystack, Meta/WhatsApp, QR/tokens, Oban workers, LiveView/admin UI, or checkout code. RED tests must fail before the domain shell exists and pass after implementation. Confirm no `sales_*` migrations and no `lib/fastcheck/sales/*.ex` resource files exist except `lib/fastcheck/sales.ex`. Performance impact should be zero because no runtime Sales path is added. |

---

## 14. Copy-Paste Agent Prompt

```text
You are implementing FastCheck Sales slice VS-01A — Ash Installation and Sales Domain Shell.

Goal:
Install and register the empty Ash 3.x Sales domain shell only.

Required context:
- FastCheck Sales is multi-channel, but WhatsApp is first.
- The Sales core will later support WhatsApp, admin-assisted sales, and web checkout.
- This slice must not implement any Sales business behavior.

Do:
1. Inspect the existing Phoenix/Elixir project structure and dependency style.
2. Add Ash 3.x and AshPostgres dependencies if not already present.
3. Register `FastCheck.Sales` as an Ash domain in the existing application config style.
4. Create `lib/fastcheck/sales.ex` as an empty Ash domain shell.
5. Keep the domain resource list empty.
6. Create RED/GREEN tests in `test/fastcheck/sales/domain_shell_test.exs` that prove:
   - `FastCheck.Sales` exists.
   - it is registered as an Ash domain.
   - it has zero resources in VS-01A.
   - no `sales_*` migrations exist.
   - no Sales resource modules exist yet.
7. Create `docs/fastcheck_sales/slices/VS-01A_ASH_INSTALLATION_AND_SALES_DOMAIN_SHELL.md` documenting what changed and what remains forbidden.
8. Run:
   - `mix deps.get`
   - `mix format --check-formatted`
   - `mix compile`
   - `mix test test/fastcheck/sales/domain_shell_test.exs`
   - `mix test` if feasible

Do not:
- Do not create TicketOffer, Order, OrderLine, CheckoutSession, PaymentAttempt, PaymentEvent, TicketIssue, DeliveryAttempt, Conversation, or StateTransition.
- Do not create any `sales_*` migrations.
- Do not add Redis code.
- Do not add Paystack code.
- Do not add Meta/WhatsApp code.
- Do not add QR/token code.
- Do not mutate Attendee, Event, scanner, Tickera sync, Android/mobile API, LiveView, or Oban logic.
- Do not add generic `update_status` actions.
- Do not upgrade unrelated dependencies.

Acceptance:
The domain shell compiles, the targeted domain-shell test passes, the domain has zero resources, no Sales resource modules/migrations exist, and existing scanner/runtime paths are untouched.
```

---

## 15. Human Review Checklist

Before marking this slice Done, verify:

```text
[ ] VS-00A, VS-00B, VS-00C, and VS-00D are accepted.
[ ] Only Ash/AshPostgres dependency changes were made.
[ ] `FastCheck.Sales` exists at `lib/fastcheck/sales.ex`.
[ ] `FastCheck.Sales` is registered in config.
[ ] The domain has zero registered resources.
[ ] No Sales resource files exist yet.
[ ] No `sales_*` migrations exist.
[ ] No Redis/Paystack/Meta/Ticketing/Attendee/scanner/mobile/UI/worker code was added.
[ ] Domain-shell tests pass.
[ ] Formatting passes.
[ ] Compilation passes.
[ ] Existing tests were run or exact limitations were documented.
[ ] Boundary documentation was created.
```

---

## 16. Next Slice

After VS-01A is complete and reviewed, continue with:

```text
VS-01B — Core Sales Resource Skeletons
```

VS-01B is the first slice that may create Ash resource skeletons, starting with:

```text
FastCheck.Sales.TicketOffer
FastCheck.Sales.Order
FastCheck.Sales.OrderLine
FastCheck.Sales.StateTransition
```

Do not start VS-01B until VS-01A is merged and stable.
