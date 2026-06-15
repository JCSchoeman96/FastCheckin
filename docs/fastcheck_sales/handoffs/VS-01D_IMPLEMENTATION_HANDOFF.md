# VS-01D Implementation Handoff

## Status

Merged.

PR: #335 — feat(sales): VS-01D ticket and delivery resource skeletons  
Merge commit: `eae832b14ae4e8462724b728c78f031d557e155f`  
Merged at: 2026-06-15T11:19:42Z  
Branch: `vs-01d-ticket-delivery-skeletons`

## What Changed

VS-01D added read-only Ash/Postgres skeletons for ticket issuance audit and
delivery attempt audit. `FastCheck.Sales` now registers nine resources through
VS-01D. One migration creates `sales_ticket_issues` and
`sales_delivery_attempts` with VS-00A status constraints, Sales foreign keys,
partial unique idempotency indexes, query-path indexes, and positive-sequence
checks for `line_item_sequence` and `attempt_number`.

`Order` gained declarative `has_many :ticket_issues` and
`has_many :delivery_attempts`. `OrderLine` gained `has_many :ticket_issues`.
No ticket issuing, QR/token generation, attendee creation, WhatsApp/email
delivery, scanner mutation, Paystack, Redis, Oban workers, or UI paths were
added.

## Files Changed

- `lib/fastcheck/sales.ex` — registers nine VS-01D Sales resources.
- `lib/fastcheck/sales/ticket_issue.ex` — read-only ticket issuance audit
  skeleton; `belongs_to :order` and `:order_line`; `has_many :delivery_attempts`;
  partial identities for `ticket_code` and `attendee_id`; `sensitive?: true` on
  `ticket_code`, `qr_token_hash`, `delivery_token_hash`, and `attendee_id`.
- `lib/fastcheck/sales/delivery_attempt.ex` — read-only delivery attempt audit
  skeleton; `belongs_to :order` and `:ticket_issue`; `sensitive?: true` on
  `recipient`, `provider_error_message`, and `failure_reason`.
- `lib/fastcheck/sales/order.ex` — declarative `has_many :ticket_issues` and
  `has_many :delivery_attempts` only; no new actions.
- `lib/fastcheck/sales/order_line.ex` — declarative `has_many :ticket_issues`
  only; no new actions.
- `priv/repo/migrations/20260615130000_create_ticket_and_delivery_resource_skeletons.exs`
  — creates the two VS-01D tables, status/channel constraints, FKs, partial
  uniques, and indexes.
- `test/fastcheck/sales/domain_shell_test.exs` — exact nine-resource domain
  registration and Sales resource file inventory through VS-01D.
- `test/fastcheck/sales/core_resource_boundary_test.exs` — guards `Conversation`
  and later runtime paths only; `TicketIssue` and `DeliveryAttempt` removed
  from forbidden lists.
- `test/fastcheck/sales/checkout_and_payment_resource_migrations_test.exs` —
  VS-01C subset assertion: seven checkout/payment tables must still exist
  (Option A).
- `test/fastcheck/sales/ticket_and_delivery_resource_skeletons_test.exs` —
  VS-01D resource metadata, read-only actions, relationships, sensitive fields,
  issuance-only `TicketIssue.status`, and forbidden workflow actions.
- `test/fastcheck/sales/ticket_and_delivery_resource_migrations_test.exs` —
  full nine-table inventory, schema/index/FK coverage, constraint failures, and
  duplicate identity failures.
- `test/fastcheck/sales/vs_01d_boundary_test.exs` — guards forbidden
  `Conversation`, ticket issuer, Paystack, workers, webhook controller, Sales
  LiveViews, delivery workers, and WhatsApp messaging paths.
- `test/fastcheck/sales/vs_01c_boundary_test.exs` — `TicketIssue` and
  `DeliveryAttempt` removed from forbidden lists; VS-01C runtime-path guards
  retained.
- `docs/fastcheck_sales/slices/VS-01D_TICKET_AND_DELIVERY_RESOURCE_SKELETONS.md`
  — documents implemented VS-01D boundary, relationships, and sensitive-field
  rules.
- `.cursor/plans/vs-01d-ticket-delivery-skeletons.plan.md` — canonical active
  implementation plan for VS-01D.

## Contracts Now Available

- `FastCheck.Sales.TicketIssue` and `FastCheck.Sales.DeliveryAttempt` exist and
  compile.
- `FastCheck.Sales` registers exactly nine resources through VS-01D.
- Tables exist after migration: `sales_ticket_issues`,
  `sales_delivery_attempts`.
- Combined with VS-01B and VS-01C, the Sales table inventory through VS-01D is
  nine `sales_*` tables.
- `TicketIssue` belongs to `Order` and `OrderLine`; `has_many :delivery_attempts`.
- `DeliveryAttempt` belongs to `Order` and `TicketIssue`.
- `TicketIssue` has unique `(sales_order_line_id, line_item_sequence)` and
  partial uniques on `ticket_code` and `attendee_id`.
- `sales_ticket_issues` enforces issuance-only `status` and
  `line_item_sequence >= 1`.
- `sales_delivery_attempts` enforces delivery `status`, allowed `channel`
  values, and `attempt_number >= 1`.
- `TicketIssue.attendee_id` is a nullable external reference with no Ash
  `belongs_to` to `Attendee` and no attendee-table FK.
- `DeliveryAttempt` is the source of truth for delivery attempt history;
  `TicketIssue.status` is issuance/validity only.
- Sensitive/restricted fields use Ash `sensitive?: true` where applicable.
- Tests guard VS-01D skeleton shape, migration contracts, and forbidden runtime
  boundaries.

## Decisions Applied

- `event_scoped_first` (unchanged from VS-01B/01C; owner boundary remains
  `event_id` on orders)
- `organization_id` deferred
- Ash resources are read-only skeletons only (`:read`, `:get_by_id`, and
  slice-specific list reads)
- no workflow actions
- no generic `update_status` or `update_state`
- no Redis ownership or mutation in this slice
- Option A migration test ownership: `core_resource_migrations_test.exs` stays
  VS-01B-scoped; `checkout_and_payment_resource_migrations_test.exs` stays
  VS-01C-scoped; `ticket_and_delivery_resource_migrations_test.exs` owns the
  full nine-table inventory
- sensitive/restricted fields must not be logged or exposed in tests/UI

## Boundaries Still Enforced

- No ticket issuing orchestration or `FastCheck.Tickets.Issuer`.
- No QR rendering, ticket-code generation, or delivery-token generation.
- No attendee creation or scanner/mobile/Android changes.
- No WhatsApp/Meta/email sending or `DeliveryAttempt` workers.
- No Paystack HTTP client, verification, or webhook controller.
- No Redis inventory, `ReservationLedger`, or Lua/scripts.
- No Oban workers.
- No `Conversation` or `TicketDeliveryToken` resources.
- No admin/customer/public UI or routes.
- No Ash policies yet.

## Tests Added Or Updated

- `test/fastcheck/sales/domain_shell_test.exs` — nine-resource registration and
  VS-01D Sales file inventory.
- `test/fastcheck/sales/core_resource_boundary_test.exs` — later-slice forbidden
  modules/paths only.
- `test/fastcheck/sales/checkout_and_payment_resource_migrations_test.exs` —
  VS-01C seven-table subset presence.
- `test/fastcheck/sales/ticket_and_delivery_resource_skeletons_test.exs` —
  VS-01D resource compile/metadata/actions/relationships/sensitive fields.
- `test/fastcheck/sales/ticket_and_delivery_resource_migrations_test.exs` —
  nine-table inventory, indexes, FKs, status/channel/attempt constraints, and
  duplicate identity failures.
- `test/fastcheck/sales/vs_01d_boundary_test.exs` — forbidden runtime modules,
  paths, and workflow actions.
- `test/fastcheck/sales/vs_01c_boundary_test.exs` — removed VS-01D resources
  from forbidden lists.

## Verification Reported

PR #335 reported:

- `mix test test/fastcheck/sales/` — 55 tests, 0 failures
- `mix precommit` — 388 tests, 0 failures, 4 skipped

GitHub CI for PR #335: Test (Elixir 1.17.3 OTP 26.2) — pass.

## Known Limitations

The new resources are skeletons only. They do not issue tickets, generate QR or
delivery tokens, create attendees, send WhatsApp/email messages, update scanner
state, or expose any operator/customer access path.

Ash field-level policies, runtime redaction beyond `sensitive?: true`, and
delivery/issuance workflow actions belong to VS-01F and later slices.

## Next Agent Guidance

Reuse the existing `FastCheck.Sales` domain, `FastCheck.Repo`, VS-01B/01C
resources, and the Ash/test patterns from VS-01D. Do not recreate
`TicketIssue` or `DeliveryAttempt`, and do not bypass their tables or indexes.

Authoritative durable tables through VS-01D:

- `sales_ticket_offers`
- `sales_orders`
- `sales_order_lines`
- `sales_state_transitions`
- `sales_checkout_sessions`
- `sales_payment_attempts`
- `sales_payment_events`
- `sales_ticket_issues`
- `sales_delivery_attempts`

Keep `event_id` as the current owner/access boundary. Do not add
`organization_id` unless a later accepted tenant-isolation slice changes that
decision.

When adding future Sales tables, follow Option A test ownership: keep earlier
migration tests subset-scoped; add or extend a later-slice migration test for
expanded `sales_%` inventory.

Keep these tests green while extending Sales:

- `test/fastcheck/sales/domain_shell_test.exs`
- `test/fastcheck/sales/core_resource_skeletons_test.exs`
- `test/fastcheck/sales/core_resource_migrations_test.exs`
- `test/fastcheck/sales/core_resource_boundary_test.exs`
- `test/fastcheck/sales/checkout_and_payment_resource_skeletons_test.exs`
- `test/fastcheck/sales/checkout_and_payment_resource_migrations_test.exs`
- `test/fastcheck/sales/ticket_and_delivery_resource_skeletons_test.exs`
- `test/fastcheck/sales/ticket_and_delivery_resource_migrations_test.exs`
- `test/fastcheck/sales/vs_01c_boundary_test.exs`
- `test/fastcheck/sales/vs_01d_boundary_test.exs`

Do not log or expose `ticket_code`, `attendee_id`, token hashes, `recipient`,
or provider error fields. Do not add ticket issuance, delivery sending,
Paystack, Redis, scanner/mobile, or UI unless the target slice explicitly owns
that behavior.

## Next Slice

Recommended next slice: VS-01E — Conversation Resource Skeleton

Entry condition: VS-01D must be merged and accepted. Read this handoff, the
VS-01C handoff, and the VS-01E feature pack before adding the conversation
skeleton resource. Accepted VS-00A–VS-00D decisions must remain available.
