# VS-01E Implementation Handoff

## Status

Merged.

PR: #337 — feat(sales): add VS-01E conversation skeleton  
Merge commit: `2ffc903fbd39e79f58620bbadab85a204830805d`  
Merged at: 2026-06-15T12:07:24Z  
Branch: `vs-01e-conversation-resource-skeleton`

## What Changed

VS-01E added the read-only Ash/Postgres skeleton for durable WhatsApp
conversation checkpoints. `FastCheck.Sales` now registers ten resources through
VS-01E. One migration creates `sales_conversations` and adds optional
`sales_orders.sales_conversation_id` linkage with `on_delete: :restrict`.

The slice stores durable checkpoint shape only: conversation state, language,
session/rate-limit key references, provider identifiers, message identifiers,
expiry, and human-handoff fields. No Meta/WhatsApp runtime, Redis session
state, checkout creation, Paystack behavior, ticket/delivery behavior, workers,
UI, scanner, attendee, event, Tickera, Android, or mobile API changes were
added.

## Files Changed

- `lib/fastcheck/sales.ex` — registers ten Sales resources through VS-01E.
- `lib/fastcheck/sales/conversation.ex` — read-only Conversation Ash resource;
  exposes `:read`, `:get_by_id`, `:list_recent`, `:list_needing_human`, and
  `:list_by_phone`; marks restricted fields `sensitive?: true`.
- `lib/fastcheck/sales/order.ex` — adds nullable `belongs_to :conversation`
  relationship only.
- `priv/repo/migrations/20260615135420_create_sales_conversations.exs` —
  creates `sales_conversations`, adds nullable `sales_orders.sales_conversation_id`,
  state/language/phone constraints, and named indexes.
- `test/fastcheck/sales/conversation_resource_skeleton_test.exs` — proves
  Conversation metadata, read-only actions, relationships, sensitive fields, and
  forbidden workflow actions.
- `test/fastcheck/sales/conversation_resource_migrations_test.exs` — proves the
  ten-table inventory, columns, indexes, constraints, optional order FK, phone
  format rejection, and duplicate phone allowance.
- `test/fastcheck/sales/vs_01e_boundary_test.exs` — guards forbidden runtime
  paths, workflow actions, and scanner/mobile/event/attendee surface changes.
- `test/fastcheck/sales/domain_shell_test.exs` — exact ten-resource domain
  registration and Sales resource file inventory through VS-01E.
- `test/fastcheck/sales/core_resource_boundary_test.exs`,
  `test/fastcheck/sales/vs_01c_boundary_test.exs`, and
  `test/fastcheck/sales/vs_01d_boundary_test.exs` — allow Conversation while
  keeping later runtime-path guards.
- `test/fastcheck/sales/ticket_and_delivery_resource_migrations_test.exs` —
  keeps VS-01D migration assertions subset-scoped per Option A.
- `docs/fastcheck_sales/slices/VS-01E_CONVERSATION_RESOURCE_SKELETON.md` —
  documents the implemented VS-01E boundary, fields, indexes, and deferred work.
- `.cursor/plans/vs-01e-conversation-resource-skeleton.plan.md` — canonical
  active implementation plan for VS-01E.

## Contracts Now Available

- `FastCheck.Sales.Conversation` exists and compiles with AshPostgres.
- `FastCheck.Sales` registers exactly ten resources through VS-01E.
- `sales_conversations` exists after migration.
- `sales_orders.sales_conversation_id` is nullable and references
  `sales_conversations.id` with `on_delete: :restrict`.
- `Conversation` has many `Order` records; `Order` optionally belongs to
  `Conversation`.
- `sales_conversations` enforces accepted Conversation states, preferred
  languages `af` / `en`, and E.164-like `phone_e164` shape.
- Indexes exist for phone lookup, WhatsApp ID lookup, session key lookup,
  human-handoff queue, state/expiry, recent message ordering, and order
  conversation lookup.
- Duplicate `phone_e164` values are allowed for historical conversation records.
- Sensitive/restricted fields are marked with Ash `sensitive?: true`.
- Tests guard skeleton shape, migration contracts, and forbidden runtime
  boundaries.

## Decisions Applied

- `event_scoped_first` remains the first-release access model.
- `organization_id` remains deferred; VS-01E adds no `organization_id` column.
- Ash resources remain read-only skeletons only.
- No workflow actions and no generic `update_status` / `update_state`.
- No Redis ownership or mutation in this slice.
- No broad unique index on `phone_e164`.
- Optional order-to-conversation linkage uses `on_delete: :restrict`.
- Option A migration test ownership continues: earlier migration tests are
  subset-scoped; VS-01E owns the full ten-table Sales inventory assertion.

## Boundaries Still Enforced

- No Meta/WhatsApp client, inbound webhook controller, or signature
  verification.
- No Redis session, rate-limit, inventory, `ReservationLedger`, or Lua/scripts.
- No conversation menu/state-machine transition implementation.
- No checkout workflow or Paystack behavior.
- No ticket issuing, QR/token generation, delivery sending, resend, or workers.
- No Oban workers.
- No scanner/mobile/Android, Attendee, Event, or Tickera changes.
- No admin/customer/public UI or routes.
- No raw WhatsApp payload or message body storage.
- No Ash policies yet.

## Tests Added Or Updated

- `test/fastcheck/sales/domain_shell_test.exs` — ten-resource registration and
  file inventory.
- `test/fastcheck/sales/conversation_resource_skeleton_test.exs` — Conversation
  resource compile/metadata/actions/relationships/sensitive fields.
- `test/fastcheck/sales/conversation_resource_migrations_test.exs` — table
  inventory, columns, indexes, FK, constraints, phone format rejection, and
  duplicate phone allowance.
- `test/fastcheck/sales/vs_01e_boundary_test.exs` — forbidden runtime paths,
  workflow actions, and unrelated surface-change guard.
- Prior VS-01C/VS-01D/core boundary tests — Conversation is no longer forbidden,
  but runtime paths remain forbidden.
- `test/fastcheck/sales/ticket_and_delivery_resource_migrations_test.exs` —
  VS-01D table inventory changed to subset presence.

## Verification Reported

PR #337 reported:

- `mix deps.get`
- `mix format --check-formatted`
- `mix compile --warnings-as-errors`
- `mix ecto.migrate`
- `mix test test/fastcheck/sales/domain_shell_test.exs`
- `mix test test/fastcheck/sales/conversation_resource_skeleton_test.exs`
- `mix test test/fastcheck/sales/conversation_resource_migrations_test.exs`
- `mix test test/fastcheck/sales/vs_01e_boundary_test.exs`
- `mix test test/fastcheck/sales/`
- `mix precommit` — 403 tests, 0 failures, 4 skipped

## Known Limitations

Conversation is a durable skeleton only. It does not start or resume
conversations, process WhatsApp messages, mutate Redis, create checkout
sessions, send Paystack links, verify payments, issue tickets, deliver tickets,
or expose support/admin/customer access.

Ash policies, actor scoping, and runtime redaction beyond `sensitive?: true`
belong to VS-01F and later security slices.

## Next Agent Guidance

Reuse the existing `FastCheck.Sales` domain, `FastCheck.Repo`, Sales resource
patterns, and VS-01E tests. Do not recreate `Conversation`, bypass
`sales_conversations`, or make Conversation mandatory for all orders.

Authoritative durable Sales tables through VS-01E:

- `sales_ticket_offers`
- `sales_orders`
- `sales_order_lines`
- `sales_state_transitions`
- `sales_checkout_sessions`
- `sales_payment_attempts`
- `sales_payment_events`
- `sales_ticket_issues`
- `sales_delivery_attempts`
- `sales_conversations`

Keep `event_id` as the current owner/access boundary and keep
`organization_id` deferred unless a later accepted tenant-isolation slice
changes that decision.

Keep these tests green while extending Sales:

- `test/fastcheck/sales/domain_shell_test.exs`
- `test/fastcheck/sales/core_resource_skeletons_test.exs`
- `test/fastcheck/sales/core_resource_migrations_test.exs`
- `test/fastcheck/sales/core_resource_boundary_test.exs`
- `test/fastcheck/sales/checkout_and_payment_resource_skeletons_test.exs`
- `test/fastcheck/sales/checkout_and_payment_resource_migrations_test.exs`
- `test/fastcheck/sales/ticket_and_delivery_resource_skeletons_test.exs`
- `test/fastcheck/sales/ticket_and_delivery_resource_migrations_test.exs`
- `test/fastcheck/sales/conversation_resource_skeleton_test.exs`
- `test/fastcheck/sales/conversation_resource_migrations_test.exs`
- `test/fastcheck/sales/vs_01c_boundary_test.exs`
- `test/fastcheck/sales/vs_01d_boundary_test.exs`
- `test/fastcheck/sales/vs_01e_boundary_test.exs`

Do not log or expose `phone_e164`, `wa_id`, `session_key`, `rate_limit_key`,
`state_data`, provider message IDs, or `handoff_reason`. Do not add WhatsApp,
Redis, checkout, Paystack, ticket/delivery, scanner/mobile, or UI behavior
unless the target slice explicitly owns it.

## Next Slice

Recommended next slice: VS-01F — Ash Policy Foundation

Entry condition: VS-01E must be merged and accepted. Read this handoff, the
VS-01B/VS-01C/VS-01D handoffs, the VS-01F feature pack, and accepted
VS-00A–VS-00D decisions before adding policy behavior across Sales resources.
