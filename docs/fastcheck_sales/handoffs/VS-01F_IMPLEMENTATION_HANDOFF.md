# VS-01F Implementation Handoff

## Status

Merged.

PR: #339 — feat(sales): add VS-01F Ash policy foundation  
Merge commit: `044e2122243fec4af07512d7a9e56181dd15ad34`  
Merged at: 2026-06-15T20:16:36Z  
Branch: `vs-01f-ash-policy-foundation`

## What Changed

VS-01F added the first Ash policy foundation across the ten existing FastCheck
Sales skeleton resources. All Sales resources now use `Ash.Policy.Authorizer`.
The slice added actor-type checks, event-scope read filters, field policies for
restricted data, a minimal SAT solver dependency required by Ash policy
execution, policy/boundary tests, and a VS-01F slice document.

No business workflow, provider integration, Redis behavior, ticket issuance,
scanner/mobile path, admin UI, route, migration, or table was added.

## Files Changed

- `lib/fastcheck/sales/policy_checks.ex` — minimal Ash policy checks for actor
  type and event-scope filters only; no Repo, Redis, cache, HTTP, or workflow
  calls.
- `lib/fastcheck/sales/ticket_offer.ex` — adds policy authorizer, direct
  `event_id` read scoping, and field policy coverage.
- `lib/fastcheck/sales/order.ex` — adds policy authorizer, direct `event_id`
  read scoping, and buyer PII field restrictions.
- `lib/fastcheck/sales/order_line.ex` — adds policy authorizer and read scoping
  through `order.event_id`.
- `lib/fastcheck/sales/checkout_session.ex` — adds policy authorizer, read
  scoping through `order.event_id`, and `hold_token` / `state_data` field
  restrictions.
- `lib/fastcheck/sales/payment_attempt.ex` — adds policy authorizer, read
  scoping through `order.event_id`, and raw provider URL/code/response field
  restrictions.
- `lib/fastcheck/sales/ticket_issue.ex` — adds policy authorizer, read scoping
  through `order.event_id`, and ticket/token hash field restrictions.
- `lib/fastcheck/sales/delivery_attempt.ex` — adds policy authorizer, read
  scoping through `order.event_id`, and recipient/provider error field
  restrictions.
- `lib/fastcheck/sales/payment_event.ex` — adds system-only read policy and
  field policies because no reliable event scope path exists yet.
- `lib/fastcheck/sales/state_transition.ex` — adds system-only read policy and
  keeps the resource append-only from the exposed action surface.
- `lib/fastcheck/sales/conversation.ex` — adds system-only read policy because
  unlinked conversation rows have no reliable event scope path yet.
- `mix.exs` / `mix.lock` — adds `simple_sat` `~> 0.1.4`, the pure-Elixir SAT
  solver needed for Ash policy execution.
- `test/fastcheck/sales/vs_01f_policy_test.exs` — proves actor behavior,
  event-scope filtering, system-only resources, restricted fields, and
  fail-closed actors.
- `test/fastcheck/sales/vs_01f_boundary_test.exs` — guards forbidden runtime
  paths, workflow actions, `organization_id`, and scanner/mobile/event/attendee
  surface changes.
- `test/fastcheck/sales/domain_shell_test.exs` — allows the single approved
  `policy_checks.ex` helper in the Sales file inventory.
- `.cursor/plans/vs-01f-ash-policy-foundation.plan.md` — canonical approved
  implementation plan.
- `docs/fastcheck_sales/slices/VS-01F_ASH_POLICY_FOUNDATION.md` — documents the
  implemented policy boundary, actor model, event scoping, restricted fields,
  and deferred work.

## Contracts Now Available

- All ten Sales resources use `Ash.Policy.Authorizer`.
- The supported Sales actor types are `:system`, `:admin`, `:operator`, and
  `:customer_session`.
- Admin/operator reads for event-scoped resources require
  `allowed_event_ids`.
- `TicketOffer` scopes reads by `event_id`.
- `Order`, `OrderLine`, `CheckoutSession`, `PaymentAttempt`, `TicketIssue`, and
  `DeliveryAttempt` scope reads by direct or relationship `order.event_id`.
- `PaymentEvent`, `StateTransition`, and `Conversation` are system-only for
  broad reads until later slices add safe scoped actions or links.
- `customer_session` cannot broadly read Sales resources.
- Operator is narrower than admin and cannot read restricted raw provider,
  token/hash, buyer PII, delivery recipient, checkout state, or WhatsApp
  checkpoint fields by default.
- `simple_sat` is available for Ash policy SAT solving.
- VS-01F tests now guard the policy boundary and forbidden runtime surface.

## Decisions Applied

- `event_scoped_first`
- `organization_id` deferred
- actor model: `system`, `admin`, `operator`, `customer_session`
- system-only reads for resources without a reliable event scope path
- operator is not equivalent to admin
- `customer_session` has no broad Sales reads
- raw provider payloads and customer/token-sensitive fields are restricted
- no workflow actions
- no generic `update_status` or `update_state`
- no Redis ownership or provider runtime behavior in this slice

## Boundaries Still Enforced

- No checkout workflow.
- No Paystack client, webhook, initialization, or verification.
- No Redis inventory, ReservationLedger, Lua/scripts, or cache behavior.
- No Meta/WhatsApp client, webhook, or conversation runtime.
- No ticket issuance, QR/token generation, delivery sending, or workers.
- No scanner, attendee, event, Tickera, Android, or mobile API changes.
- No admin/customer/public UI, routes, controllers, or LiveViews.
- No migrations, new tables, new columns, or `organization_id`.
- No broad admin/operator reads for resources without safe event scope.

## Tests Added Or Updated

- `test/fastcheck/sales/vs_01f_policy_test.exs` — verifies authorized Ash reads
  use explicit actors, customer sessions are denied, admin/operator reads are
  event-filtered, system-only resources deny admin/operator, restricted fields
  return `Ash.ForbiddenField`, and unknown actors fail closed.
- `test/fastcheck/sales/vs_01f_boundary_test.exs` — verifies forbidden runtime
  paths/actions remain absent, `organization_id` is not introduced, and
  scanner/mobile/event/attendee/Tickera/router surfaces are untouched.
- `test/fastcheck/sales/domain_shell_test.exs` — updates Sales file inventory
  to include `policy_checks.ex`.

## Verification Reported

PR #339 body reported:

- `mix format --check-formatted`
- `mix compile --warnings-as-errors`
- `mix test test/fastcheck/sales/vs_01f_policy_test.exs`
- `mix test test/fastcheck/sales/vs_01f_boundary_test.exs`
- `mix test test/fastcheck/sales/`
- `mix test`
- `mix precommit`

Implementation verification reported:

- `mix test` — 416 tests, 0 failures, 4 skipped.
- `mix precommit` — 416 tests, 0 failures, 4 skipped.

GitHub CI for PR #339:

- `Test (Elixir 1.17.3 OTP 26.2)` — pass.

## Known Limitations

The policy foundation is intentionally skeletal. It does not add customer-safe
service-flow reads, admin dashboards, manual review operations, workflow
actions, scoped reads for `PaymentEvent`, `StateTransition`, or unlinked
`Conversation`, or any runtime integration.

Field policies restrict access but do not implement UI masking or support views.
Those belong to later admin/customer slices.

## Next Agent Guidance

Reuse `FastCheck.Sales.PolicyChecks` for actor-type and event-scope Ash policy
checks. Do not expand it with Repo calls, Redis calls, HTTP calls, caching,
workflow decisions, or provider/business logic.

Reuse the existing policy shape on Sales resources:

- system bypass for event-scoped resources
- strict admin/operator actor checks
- filter policy using `EventAllowed`
- system-only strict reads where no safe event scope path exists
- field policies with `private_fields(:include)` for sensitive fields

Do not bypass Ash policies with direct broad reads in future Sales workflow,
admin, provider, or customer slices. Do not make `PaymentEvent`,
`StateTransition`, or unlinked `Conversation` broadly readable by admin/operator
until a later slice adds safe scoped actions or links.

Keep these tests green while extending Sales:

- `test/fastcheck/sales/vs_01f_policy_test.exs`
- `test/fastcheck/sales/vs_01f_boundary_test.exs`
- all prior Sales skeleton, migration, and boundary tests under
  `test/fastcheck/sales/`

## Next Slice

Recommended next slice: VS-01G — Index and Migration Verification

Entry condition: VS-01F must remain merged and accepted. The VS-01G agent must
read this handoff, the VS-01B through VS-01E handoffs, the VS-01G feature pack,
and the current Sales migrations/tests before verifying or correcting indexes,
constraints, identities, and migration coverage.
