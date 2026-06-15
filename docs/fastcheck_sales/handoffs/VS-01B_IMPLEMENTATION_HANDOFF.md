# VS-01B Implementation Handoff

## Status

Merged.

PR: #331 — Add core Sales resource skeletons  
Merge commit: `daab688bd0f4cfec577e8976447740ea389e2331`  
Merged at: 2026-06-15T08:46:21Z  
Branch: `vs-01b-core-sales-resource-skeletons`

## What Changed

VS-01B added the first durable FastCheck Sales Ash/Postgres skeletons. The
`FastCheck.Sales` domain now registers ticket offers, orders, order lines, and
state transitions. A migration creates the four matching `sales_*` tables with
integer-cent money fields, event-scoped columns, constraints, indexes, and
order-line foreign keys.

No checkout, payment processing, inventory mutation, ticket issuance, scanner,
mobile, admin, customer, or provider runtime path was added.

## Files Changed

- `lib/fastcheck/sales.ex` — registers exactly the four VS-01B Sales resources.
- `lib/fastcheck/sales/ticket_offer.ex` — read-only AshPostgres ticket-offer
  configuration skeleton.
- `lib/fastcheck/sales/order.ex` — read-only AshPostgres durable order skeleton.
- `lib/fastcheck/sales/order_line.ex` — read-only AshPostgres order-line price
  snapshot skeleton with relationships to Order and TicketOffer.
- `lib/fastcheck/sales/state_transition.ex` — read-only AshPostgres audit-row
  skeleton; no transition-recording helper.
- `priv/repo/migrations/20260615110000_create_core_sales_resource_skeletons.exs`
  — creates `sales_ticket_offers`, `sales_orders`, `sales_order_lines`, and
  `sales_state_transitions`.
- `test/fastcheck/sales/domain_shell_test.exs` — updates VS-01A empty-domain
  assertions to VS-01B exact resource registration.
- `test/fastcheck/sales/core_resource_skeletons_test.exs` — proves resource
  modules, AshPostgres data layer, attributes, read-only actions,
  relationships, and deferred organization tenancy.
- `test/fastcheck/sales/core_resource_migrations_test.exs` — proves tables,
  columns, integer money fields, indexes, partial unique indexes, FKs, and DB
  constraints.
- `test/fastcheck/sales/core_resource_boundary_test.exs` — guards forbidden
  later resources and runtime surface changes.
- `docs/fastcheck_sales/slices/VS-01B_CORE_SALES_RESOURCE_SKELETONS.md` —
  documents the implemented VS-01B boundary and deferred tenancy.

## Contracts Now Available

- `FastCheck.Sales.TicketOffer`, `FastCheck.Sales.Order`,
  `FastCheck.Sales.OrderLine`, and `FastCheck.Sales.StateTransition` exist.
- `FastCheck.Sales` registers exactly those four resources for VS-01B.
- The following tables exist after migration:
  `sales_ticket_offers`, `sales_orders`, `sales_order_lines`,
  `sales_state_transitions`.
- `OrderLine` belongs to `Order` and `TicketOffer`; `Order` and `TicketOffer`
  have `has_many :order_lines`.
- Sales money fields are integer columns.
- `event_id` is the first-release Sales owner/access boundary.
- Tests now guard that later Sales resources and forbidden runtime paths are
  still absent.

## Decisions Applied

- `event_scoped_first`
- `organization_id` deferred
- integer cents for money
- Ash resources are read-only skeletons only
- no workflow actions
- no generic `update_status` or `update_state`
- no `StateTransition.record_transition` helper
- no Redis ownership in this slice

## Boundaries Still Enforced

- No checkout workflow.
- No Paystack client, webhook, transaction initialization, or verification.
- No Redis inventory, ReservationLedger, or Lua/scripts.
- No Meta/WhatsApp integration.
- No QR/token generation.
- No ticket issuance or attendee creation.
- No scanner/mobile/Android changes.
- No admin/customer/public UI or routes.
- No Ash policies yet.
- No later resources: CheckoutSession, PaymentAttempt, PaymentEvent,
  TicketIssue, DeliveryAttempt, or Conversation.

## Tests Added Or Updated

- `test/fastcheck/sales/domain_shell_test.exs` — exact domain registration and
  VS-01B resource files.
- `test/fastcheck/sales/core_resource_skeletons_test.exs` — resource metadata,
  read-only actions, relationships, and no `organization_id`.
- `test/fastcheck/sales/core_resource_migrations_test.exs` — schema/index/FK
  and constraint coverage.
- `test/fastcheck/sales/core_resource_boundary_test.exs` — forbidden modules,
  paths, and unrelated surface-change guard.

## Verification Reported

PR #331 reported:

- `mix test test/fastcheck/sales/core_resource_skeletons_test.exs`
- `mix test test/fastcheck/sales/core_resource_migrations_test.exs`
- `mix test test/fastcheck/sales/core_resource_boundary_test.exs`
- `mix test test/fastcheck/sales/domain_shell_test.exs`

The merge commit summary also records the implementation scope:

- Register read-only Ash resources for offers, orders, order lines, and state
  transitions.
- Add Postgres tables, constraints, indexes, and boundary tests.

No full-suite, precommit, or CI result was present in the PR body inspected for
this handoff.

## Known Limitations

The Sales resources are skeletons only. They do not create orders, reserve
inventory, initialize or verify payments, issue tickets, expose admin/customer
access, enforce Ash policies, or append transitions. Live inventory remains a
future Redis/ReservationLedger concern.

`PaymentAttempt`, `PaymentEvent`, and `CheckoutSession` do not exist yet.

## Next Agent Guidance

Reuse the existing `FastCheck.Sales` domain, `FastCheck.Repo`, and the Ash
resource/test patterns added in VS-01B. Do not recreate the four core resources
or bypass their tables.

Use `sales_orders`, `sales_order_lines`, `sales_ticket_offers`, and
`sales_state_transitions` as the authoritative durable Sales foundation. Keep
`event_id` as the current owner/access boundary and do not add
`organization_id` unless a later accepted tenant-isolation slice changes that
decision.

Keep these tests green while extending Sales skeletons:

- `test/fastcheck/sales/domain_shell_test.exs`
- `test/fastcheck/sales/core_resource_skeletons_test.exs`
- `test/fastcheck/sales/core_resource_migrations_test.exs`
- `test/fastcheck/sales/core_resource_boundary_test.exs`

Do not add runtime checkout, Paystack, Redis, WhatsApp, ticket issuance,
scanner/mobile, admin/customer UI, or policy behavior unless the next slice
explicitly owns it.

## Next Slice

Recommended next slice: VS-01C — Checkout and Payment Resource Skeletons

Entry condition: VS-01B must be merged and accepted, and the accepted VS-00A,
VS-00B, VS-00C, and VS-00D decisions must remain available. The VS-01C agent
must read this handoff, the VS-01B implementation doc, and the VS-01C feature
pack before adding any checkout/payment skeleton resources.
