# VS-03 Implementation Handoff

## Status

Merged.

PR: #345 — feat(sales): implement VS-03 ticket offer management  
Merge commit: `bff749ce171977335b275b3f4d478e20bb8c163f`  
Merged at: 2026-06-16T08:56:41Z  
Branch: `vs-03-ticket-offer-management`

## What Changed

VS-03 implemented durable `TicketOffer` management in Sales with named Ash
actions, validations, policy-scoped reads/mutations, nullable sales windows, a
small centralized offer-cache invalidation boundary, focused tests, and slice
documentation.

The slice stayed within Sales offer-management scope and did not add checkout,
inventory authority, payment/provider integration, ticket issuance runtime, or
scanner/mobile/UI behavior.

## Files Changed

- `lib/fastcheck/sales/ticket_offer.ex` — adds VS-03 named actions, active-offer filtering, checkout eligibility read, validations, and policy rules (including system read-only scope and archived-offer guard for `enable_sales`).
- `lib/fastcheck/sales/policy_checks.ex` — extends event-scope filter check to support configurable actor types used by VS-03 policies.
- `lib/fastcheck/sales/offers/cache_invalidation.ex` — centralized offer cache invalidation boundary using existing cache manager key-pattern invalidation.
- `priv/repo/migrations/20260616102500_allow_nullable_sales_ticket_offer_windows.exs` — makes `starts_at`/`ends_at` nullable and adds offer channel/window/max-per-order constraints with explicit reversible `from:` metadata.
- `test/fastcheck/sales/ticket_offer_test.exs` — proves action behavior, validation failures, active filtering, checkout eligibility, idempotent enable/disable, and archived-offer enable rejection.
- `test/fastcheck/sales/ticket_offer_policy_test.exs` — proves actor permissions including operator read-only, customer-session controlled reads, and system mutation denial.
- `test/fastcheck/sales/ticket_offer_cache_invalidation_test.exs` — proves mutation actions trigger centralized event-offer cache invalidation.
- `test/fastcheck/sales/ticket_offer_boundary_test.exs` — guards VS-03 out-of-scope runtime boundaries.
- `test/fastcheck/sales/core_resource_skeletons_test.exs` — updates baseline assertions to allow VS-03 TicketOffer action surface.
- `test/fastcheck/sales/core_resource_migrations_test.exs` — updates fixture data for the new window validity constraint.
- `test/fastcheck/sales/vs_01f_policy_test.exs` — updates fixture data to satisfy window validity constraint.
- `docs/fastcheck_sales/slices/VS-03_TICKET_OFFER_MANAGEMENT.md` — documents implemented VS-03 scope, boundaries, and cache contract.
- `.cursor/plans/vs-03-ticket-offer-management.plan.md` — canonical implementation plan artifact used during execution.

## Contracts Now Available

- `FastCheck.Sales.TicketOffer` now exposes the VS-03 named actions:
  `create_offer`, `update_offer`, `enable_sales`, `disable_sales`,
  `list_active_for_event`, and `get_available_for_checkout`.
- Active-offer reads now enforce event scope, enabled state, non-archived
  status, open-ended window semantics, and channel compatibility.
- `enable_sales` explicitly rejects archived offers.
- System actor access is read-only for controlled reads; system cannot mutate
  offers.
- `sales_ticket_offers.starts_at` and `sales_ticket_offers.ends_at` are now
  nullable for open-ended windows.
- `FastCheck.Sales.Offers.CacheInvalidation.invalidate_event_offers/1` is the
  central mutation-side cache invalidation boundary.
- New ticket-offer tests now guard action behavior, policy boundaries,
  invalidation behavior, and out-of-scope restrictions.

## Decisions Applied

- `event_scoped_first`
- `organization_id` deferred
- `TicketOffer` remains durable config only
- named actions only (no generic status updater)
- system actor limited to controlled reads
- no Redis live inventory ownership in this slice
- no checkout/order workflow ownership in this slice

## Boundaries Still Enforced

- No checkout workflow implementation.
- No Redis inventory authority, ReservationLedger, or Lua/scripts.
- No Paystack integration or verification runtime.
- No Meta/WhatsApp runtime integration.
- No ticket issuance runtime behavior.
- No attendee/scanner/mobile/Android surface changes.
- No admin/customer UI or router/controller work for Sales offers.

## Tests Added Or Updated

- `test/fastcheck/sales/ticket_offer_test.exs` — VS-03 action, validation, filtering, and archived-enable guard behavior.
- `test/fastcheck/sales/ticket_offer_policy_test.exs` — VS-03 actor policy behavior including system mutate denial.
- `test/fastcheck/sales/ticket_offer_cache_invalidation_test.exs` — centralized cache invalidation invocation.
- `test/fastcheck/sales/ticket_offer_boundary_test.exs` — explicit out-of-scope boundary checks.
- `test/fastcheck/sales/core_resource_skeletons_test.exs` — baseline action-surface alignment with VS-03.
- `test/fastcheck/sales/core_resource_migrations_test.exs` — fixture compatibility with window constraint.
- `test/fastcheck/sales/vs_01f_policy_test.exs` — fixture compatibility with window constraint.

## Verification Reported

From PR #345 body:

- `mix compile --warnings-as-errors`
- `mix test test/fastcheck/sales/ticket_offer_test.exs test/fastcheck/sales/ticket_offer_policy_test.exs test/fastcheck/sales/ticket_offer_cache_invalidation_test.exs test/fastcheck/sales/ticket_offer_boundary_test.exs`
- `mix test test/fastcheck/sales/`
- `mix test`
- `mix precommit`

Follow-up review-fix verification (same command set rerun) also passed before
merge completion of final branch state.

GitHub CI for PR #345 was reported green.

## Known Limitations

VS-03 does not implement live inventory/reservation authority, checkout/order
execution, payment/provider runtime, ticket issuance runtime, or Sales UI/API
surfaces. Those remain owned by later slices.

`TicketOffer` actions enforce durable eligibility only; live availability is
still not derived from `configured_quantity_available`.

## Next Agent Guidance

Reuse and extend these authoritative assets:

- `FastCheck.Sales.TicketOffer` for all future offer reads/mutations.
- `sales_ticket_offers` as the durable offer table.
- `FastCheck.Sales.Offers.CacheInvalidation` for offer-cache mutation side
  effects.
- VS-03 ticket-offer tests as baseline behavior guards.

Do not recreate or bypass:

- do not bypass Ash action policies with direct broad reads
- do not reintroduce system mutation on TicketOffer without an explicit approved
  maintenance slice
- do not add inventory/checkout/payment side effects inside TicketOffer actions
- do not scatter cache invalidation logic across callers

Keep these tests green when extending Sales:

- `test/fastcheck/sales/ticket_offer_test.exs`
- `test/fastcheck/sales/ticket_offer_policy_test.exs`
- `test/fastcheck/sales/ticket_offer_cache_invalidation_test.exs`
- `test/fastcheck/sales/ticket_offer_boundary_test.exs`
- existing VS-01F / VS-01G Sales boundary/index policy tests

## Next Slice

Recommended next slice: VS-04A — Inventory Reservation Ledger

Entry condition: VS-03 remains merged and green; future work must treat
`TicketOffer` as durable configuration input and implement live availability
authority outside of TicketOffer (Redis/ReservationLedger boundary), while
preserving VS-03 policy and boundary tests.
