# VS-01C Implementation Handoff

## Status

Merged.

PR: #333 — feat(sales): VS-01C checkout and payment resource skeletons  
Merge commit: `84abec4abaf67d27b7aa2037e3846683afddf2db`  
Merged at: 2026-06-15T10:19:41Z  
Branch: `vs-01c-checkout-payment-skeletons`

## What Changed

VS-01C added read-only Ash/Postgres skeletons for checkout and payment
persistence. `FastCheck.Sales` now registers seven resources through VS-01C.
One migration creates `sales_checkout_sessions`, `sales_payment_attempts`, and
`sales_payment_events` with VS-00A status constraints, foreign keys to
`sales_orders` where appropriate, named indexes, partial unique webhook dedupe
indexes, and a dedupe-identity check on payment events.

`Order` gained declarative `has_one :checkout_session` and
`has_many :payment_attempts`. No checkout workflow, Paystack integration, Redis
mutation, webhook processing, Oban workers, ticket issuance, scanner/mobile, or
UI paths were added.

## Files Changed

- `lib/fastcheck/sales.ex` — registers seven VS-01C Sales resources.
- `lib/fastcheck/sales/checkout_session.ex` — read-only checkout session skeleton;
  `belongs_to :order`; `sensitive?: true` on `hold_token`.
- `lib/fastcheck/sales/payment_attempt.ex` — read-only payment attempt skeleton;
  `belongs_to :order`; sensitive provider fields marked with `sensitive?: true`.
- `lib/fastcheck/sales/payment_event.ex` — read-only raw provider event skeleton;
  no `PaymentAttempt` relationship; `sensitive?: true` on `raw_payload`.
- `lib/fastcheck/sales/order.ex` — declarative `has_one :checkout_session` and
  `has_many :payment_attempts` only; no new actions.
- `priv/repo/migrations/20260615120000_create_checkout_and_payment_resource_skeletons.exs`
  — creates the three VS-01C tables, constraints, FKs, and indexes.
- `test/fastcheck/sales/domain_shell_test.exs` — exact seven-resource domain
  registration and Sales resource file inventory through VS-01C.
- `test/fastcheck/sales/core_resource_boundary_test.exs` — guards later slices
  only; VS-01C resources removed from forbidden lists.
- `test/fastcheck/sales/core_resource_migrations_test.exs` — VS-01B subset
  assertion: original four tables must still exist.
- `test/fastcheck/sales/checkout_and_payment_resource_skeletons_test.exs` — VS-01C
  resource metadata, read-only actions, relationships, sensitive fields, and no
  `organization_id`.
- `test/fastcheck/sales/checkout_and_payment_resource_migrations_test.exs` — full
  seven-table inventory, schema/index/FK coverage, and DB constraint failures.
- `test/fastcheck/sales/vs_01c_boundary_test.exs` — guards forbidden Paystack,
  worker, ReservationLedger, ticket issuer, webhook controller, and later
  resource creep.
- `docs/fastcheck_sales/slices/VS-01C_CHECKOUT_AND_PAYMENT_RESOURCE_SKELETONS.md`
  — documents implemented VS-01C boundary, relationships, and sensitive-field
  rules.

## Contracts Now Available

- `FastCheck.Sales.CheckoutSession`, `FastCheck.Sales.PaymentAttempt`, and
  `FastCheck.Sales.PaymentEvent` exist and compile.
- `FastCheck.Sales` registers exactly seven resources through VS-01C.
- Tables exist after migration:
  `sales_checkout_sessions`, `sales_payment_attempts`, `sales_payment_events`.
- Combined with VS-01B, the Sales table inventory through VS-01C is seven
  `sales_*` tables.
- `CheckoutSession` belongs to `Order` with unique `sales_order_id`.
- `PaymentAttempt` belongs to `Order`.
- `PaymentEvent` has no FK to `PaymentAttempt`.
- `sales_payment_events` enforces
  `provider_event_id IS NOT NULL OR payload_hash IS NOT NULL`
  (`sales_payment_events_dedupe_identity_present`).
- Partial unique indexes support webhook dedupe by
  `(provider, provider_event_id)` or `(provider, payload_hash)`.
- Sensitive provider fields use Ash `sensitive?: true` where applicable.
- Tests guard VS-01C skeleton shape, migration contracts, and forbidden runtime
  boundaries.

## Decisions Applied

- `event_scoped_first` (unchanged from VS-01B; owner boundary remains `event_id`
  on orders)
- `organization_id` deferred
- integer cents for money
- Ash resources are read-only skeletons only (`:read`, `:get_by_id`)
- no workflow actions
- no generic `update_status` or `update_state`
- no Redis ownership or mutation in this slice
- VS-01B migration tests remain subset-scoped; VS-01C migration test owns the
  full seven-table inventory (Option A)
- sensitive provider fields must not be logged or exposed in tests/UI

## Boundaries Still Enforced

- No checkout session creation workflow.
- No inventory hold attach/release/expiry behavior.
- No Paystack HTTP client, transaction initialization, verification, or webhook
  controller.
- No webhook signature verification or payment event processing.
- No Redis inventory, `ReservationLedger`, or Lua/scripts.
- No Oban payment workers.
- No Meta/WhatsApp integration.
- No QR/token generation.
- No ticket issuance, `TicketIssue`, `DeliveryAttempt`, or `Conversation`
  resources.
- No attendee creation or scanner/mobile/Android changes.
- No admin/customer/public UI or routes.
- No Ash policies yet.

## Tests Added Or Updated

- `test/fastcheck/sales/domain_shell_test.exs` — seven-resource registration and
  VS-01C Sales file inventory.
- `test/fastcheck/sales/core_resource_boundary_test.exs` — later-slice forbidden
  modules/paths only.
- `test/fastcheck/sales/core_resource_migrations_test.exs` — VS-01B four-table
  subset presence.
- `test/fastcheck/sales/checkout_and_payment_resource_skeletons_test.exs` —
  VS-01C resource compile/metadata/actions/relationships/sensitive fields.
- `test/fastcheck/sales/checkout_and_payment_resource_migrations_test.exs` —
  seven-table inventory, indexes, FKs, status/amount/currency/dedupe constraint
  failures.
- `test/fastcheck/sales/vs_01c_boundary_test.exs` — forbidden runtime modules,
  paths, and workflow actions.

## Verification Reported

PR #333 reported:

- `mix test test/fastcheck/sales/` — 37 tests, 0 failures
- `mix precommit` — 370 tests, 0 failures, 4 skipped

Post-review fix commit `613c32e` added the payment-event dedupe identity
constraint and migration test; merged as part of `84abec4`.

GitHub CI for PR #333: Test (Elixir 1.17.3 OTP 26.2) — pass.

## Known Limitations

The new resources are skeletons only. They do not create checkout sessions,
attach Redis holds, initialize or verify Paystack payments, store webhooks at
runtime, process payment events, mutate order status, issue tickets, or expose
any operator/customer access path.

`PaymentEvent` is not linked to `PaymentAttempt` by FK; later slices must match
by `provider_reference` and related provider fields.

Ash field-level policies, retention enforcement, and runtime redaction beyond
`sensitive?: true` belong to VS-01F and later security slices.

## Next Agent Guidance

Reuse the existing `FastCheck.Sales` domain, `FastCheck.Repo`, VS-01B core
resources, and the Ash/test patterns from VS-01B and VS-01C. Do not recreate
`CheckoutSession`, `PaymentAttempt`, or `PaymentEvent`, and do not bypass their
tables or indexes.

Authoritative durable tables through VS-01C:

- `sales_ticket_offers`
- `sales_orders`
- `sales_order_lines`
- `sales_state_transitions`
- `sales_checkout_sessions`
- `sales_payment_attempts`
- `sales_payment_events`

Keep `event_id` as the current owner/access boundary. Do not add
`organization_id` unless a later accepted tenant-isolation slice changes that
decision.

When adding future Sales tables, follow Option A test ownership: keep
`core_resource_migrations_test.exs` VS-01B-scoped; add or extend a later-slice
migration test for expanded `sales_%` inventory.

Keep these tests green while extending Sales:

- `test/fastcheck/sales/domain_shell_test.exs`
- `test/fastcheck/sales/core_resource_skeletons_test.exs`
- `test/fastcheck/sales/core_resource_migrations_test.exs`
- `test/fastcheck/sales/core_resource_boundary_test.exs`
- `test/fastcheck/sales/checkout_and_payment_resource_skeletons_test.exs`
- `test/fastcheck/sales/checkout_and_payment_resource_migrations_test.exs`
- `test/fastcheck/sales/vs_01c_boundary_test.exs`

Do not log or expose `authorization_url`, `access_code`, raw provider payloads,
or `hold_token`. Do not add Paystack, Redis, webhook workers, checkout workflow
actions, or UI unless the target slice explicitly owns that behavior.

## Next Slice

Recommended next slice: VS-01D — Ticket and Delivery Resource Skeletons

Entry condition: VS-01C must be merged and accepted. Read this handoff, the
VS-01B handoff, and the VS-01D feature pack before adding ticket/delivery
skeleton resources. Accepted VS-00A–VS-00D decisions must remain available.
