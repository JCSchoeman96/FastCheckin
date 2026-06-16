# VS-05A Implementation Handoff

## Status

Merged.

PR: #355 — feat(sales): VS-05A secondary sales entry points  
Merge commit: `56133f1feeeebbc3bd0143961040fd33598f1dfe`  
Merged at: 2026-06-16T16:37:42Z  
Branch: `vs-05a-secondary-sales-entry-points`

## What Changed

VS-05A added thin secondary Sales checkout entrypoints for admin-assisted and
internal-pilot channels. A new adapter module delegates all checkout creation to
the existing VS-05 `Checkout.start_checkout/3` boundary, maps `source_channel`
server-side, lists offers through Ash `:list_active_for_event`, and performs safe
event lookup without raising on missing events.

Dashboard-protected LiveViews expose checkout forms at
`/dashboard/sales/checkout/:event_id` and
`/dashboard/sales/internal-pilot/checkout/:event_id`. Internal pilot is gated by
`:sales_internal_pilot_enabled` / `SALES_INTERNAL_PILOT_ENABLED` (default off in
prod). Public web checkout was intentionally not added.

Post-merge review fix in the same squash merge required strict full-string
integer parsing for route params and form values, and strengthened boundary
tests proving LiveViews do not call `Checkout.start_checkout/3` directly.

## Files Changed

- `lib/fastcheck/sales/secondary_entrypoints.ex` — sole adapter calling
  `Checkout.start_checkout/3`; server-side `source_channel`; Ash offer reads;
  strict integer parsing; safe event fetch; safe error messages.
- `lib/fastcheck_web/live/sales/admin_checkout_live.ex` — admin-assisted checkout
  UI; session username helper; mount-scoped idempotency key.
- `lib/fastcheck_web/live/sales/internal_pilot_checkout_live.ex` — internal
  pilot checkout UI; config gate; same idempotency/session patterns.
- `lib/fastcheck_web/router.ex` — dashboard-auth Sales routes.
- `config/config.exs` — `:sales_internal_pilot_enabled` default for dev.
- `config/runtime.exs` — `SALES_INTERNAL_PILOT_ENABLED` (default false in prod).
- `config/test.exs` — enables internal pilot in test.
- `test/fastcheck/sales/secondary_entrypoints_test.exs` — adapter channel mapping,
  idempotency replay, offer-channel filters, strict parsing, safe event fetch.
- `test/fastcheck_web/sales/admin_checkout_live_test.exs` — admin LiveView auth,
  happy path, invalid event redirect, idempotency key stability on error.
- `test/fastcheck_web/sales/internal_pilot_checkout_test.exs` — pilot auth,
  config gate, enabled render.
- `test/fastcheck_web/sales/secondary_entrypoints_policy_test.exs` — unauth
  redirects; public web checkout 404.
- `test/fastcheck_web/sales/secondary_entrypoints_boundary_test.exs` — forbidden
  fragment scan; only adapter may reference `Checkout.start_checkout`.
- `test/fastcheck_web/sales/secondary_entrypoints_log_redaction_test.exs` — no
  buyer PII in adapter checkout logs.
- `test/support/sales_web_fixtures.ex` — event/offer helpers for Sales web tests.
- `test/support/sales_boundary_allowlist.ex` — VS-05A allowlist for historical
  Sales boundary git-diff tests.
- Historical Sales boundary tests — removed obsolete `live/sales` forbidden-path
  assertions; allow VS-05A file changes in git-diff guards.
- `test/fastcheck/sales/domain_shell_test.exs` — file inventory includes
  `secondary_entrypoints.ex`.
- `docs/fastcheck_sales/slices/VS-05A_SECONDARY_SALES_ENTRY_POINTS.md` — slice
  summary.
- `.cursor/plans/vs-05a-secondary-sales-entry-points.plan.md` — canonical
  implementation plan artifact.

## Contracts Now Available

- `FastCheck.Sales.SecondaryEntrypoints` is the approved secondary-channel adapter
  for admin-assisted and internal-pilot checkout starts.
- `SecondaryEntrypoints.start_admin_checkout/4` sets `source_channel: "admin"`.
- `SecondaryEntrypoints.start_internal_pilot_checkout/4` sets
  `source_channel: "internal_pilot"` when pilot is enabled.
- `SecondaryEntrypoints.list_offers_for_channel/3` reads Ash
  `:list_active_for_event` with `event_id`, `sales_channel`, and `as_of`.
- `SecondaryEntrypoints.parse_event_id/1` and form integer parsing require full
  `Integer.parse` matches (`{int, ""}`); partial strings like `"1abc"` reject.
- LiveView routes under `dashboard_auth`:
  - `/dashboard/sales/checkout/:event_id`
  - `/dashboard/sales/internal-pilot/checkout/:event_id`
- `GET /events/:event_id/checkout` does not exist (public web deferred).
- Mount-scoped idempotency keys live in LiveView assigns; success or explicit
  reset rotates; validation/checkout errors keep the same key.
- Dashboard user is derived from LiveView session `:dashboard_username`, not conn
  assigns.
- `:sales_internal_pilot_enabled` / `SALES_INTERNAL_PILOT_ENABLED` gate pilot UI.

## Decisions Applied

- `whatsapp_first_paid_core` — WhatsApp not implemented here.
- VS-00D launch scope — `admin_assisted_sales` and `internal_pilot_sales` only;
  `web_checkout_sales` deferred.
- `event_scoped_first`
- `organization_id` deferred
- All checkout creation remains in `Checkout.start_checkout/3`; adapters do not
  own inventory, payment, or ticket logic.
- Operators remain forbidden at checkout (`:admin` actor from dashboard session).
- No new Ash resources, migrations, or schema changes.

## Boundaries Still Enforced

- No public web checkout route or `customer_session` UI.
- No Paystack client, initialization, webhooks, or payment verification.
- No Meta/WhatsApp runtime, conversations, or outbound messaging.
- No ticket issuance, attendee bridge, QR, or delivery runtime.
- No scanner, mobile API, attendee/event domain, or Tickera changes.
- No direct Redis mutation outside VS-05 checkout core / `ReservationLedger`.
- LiveViews must not call `Checkout.start_checkout/3` directly.
- No admin order dashboard, refund/revocation, or manual-review operations.
- No payment link generation; checkout stops at `awaiting_payment` with hold.

## Tests Added Or Updated

- `test/fastcheck/sales/secondary_entrypoints_test.exs` — adapter uses checkout
  core; channel spoof resistance; idempotency replay; admin/internal offer-channel
  filters; disabled/archived exclusion; strict integer parsing.
- `test/fastcheck_web/sales/admin_checkout_live_test.exs` — authenticated admin
  flow; safe missing-event handling; idempotency key kept on validation error.
- `test/fastcheck_web/sales/internal_pilot_checkout_test.exs` — auth required;
  pilot disabled redirect; enabled render.
- `test/fastcheck_web/sales/secondary_entrypoints_policy_test.exs` — dashboard
  auth redirects; deferred public web 404.
- `test/fastcheck_web/sales/secondary_entrypoints_boundary_test.exs` — no
  Paystack/WhatsApp/Redis/direct Ash creates in adapter/LiveView sources; only
  adapter references `Checkout.start_checkout`.
- `test/fastcheck_web/sales/secondary_entrypoints_log_redaction_test.exs` — no
  PII in adapter logs.
- Updated historical Sales boundary tests and `domain_shell_test.exs` for VS-05A
  file inventory and git-diff allowlist.

## Verification Reported

From PR #355 body and final implementation (includes review-fix commit):

- `mix format --check-formatted` — passed
- `mix compile --warnings-as-errors` — passed
- `mix test test/fastcheck/sales/secondary_entrypoints_test.exs` — passed
- `mix test test/fastcheck_web/sales/` — passed
- `mix test test/fastcheck/sales/checkout_* test/fastcheck/sales/order_checkout_core_test.exs` — passed
- `mix test test/fastcheck/sales/` — passed
- `mix test` — 537 tests, 0 failures, 4 skipped (after review-fix commit)
- `mix precommit` — passed

GitHub CI for PR #355:

- `Test (Elixir 1.17.3 OTP 26.2)` — pass

## Known Limitations

- Checkout stops at `awaiting_payment`; no Paystack payment link or paid-state
  wiring.
- No public `web_checkout_sales` path; `customer_session` checkout UI not shipped.
- Dashboard auth is a single shared admin credential; no per-user event ACL beyond
  selected `event_id` validation.
- No admin order listing, payment status UI, or manual review surfaces (VS-12+).
- Internal pilot must stay config-gated in production.
- Offer display reads durable eligibility only; live availability still comes
  from VS-05 inventory holds at checkout time.

## Next Agent Guidance

Reuse directly:

- `FastCheck.Sales.SecondaryEntrypoints` for new secondary channel adapters
  (WhatsApp should get its own adapter later, not bypass this pattern).
- `FastCheck.Sales.Checkout.start_checkout/3` for all checkout creation.
- Ash `:list_active_for_event` via `SecondaryEntrypoints.list_offers_for_channel/3`
  or equivalent `Ash.Query.for_read` pattern.
- `test/support/sales_web_fixtures.ex` and `test/support/sales_checkout_fixtures.ex`.
- VS-05A web and adapter tests as regression guards.
- `docs/fastcheck_sales/slices/VS-05A_SECONDARY_SALES_ENTRY_POINTS.md` for
  slice-local behavior summary.

Do not:

- call `Checkout.start_checkout/3` from LiveViews, controllers, or new channel code
  outside an approved adapter module
- accept `source_channel` or trusted `idempotency_key` from client params
- add public web checkout without an explicit later slice and VS-00D scope update
- bypass strict integer parsing for route params or checkout form values
- add Paystack/WhatsApp/ticket/scanner/mobile changes inside entrypoint slices

Keep green when extending Sales:

- `test/fastcheck/sales/secondary_entrypoints_test.exs`
- `test/fastcheck_web/sales/*`
- all VS-05 checkout tests under `test/fastcheck/sales/checkout_*` and
  `order_checkout_core_test.exs`
- full `mix test test/fastcheck/sales/`

Production config note: set `SALES_INTERNAL_PILOT_ENABLED=true` only when internal
pilot routes should be available in prod.

## Next Slice

Recommended next slice:  
VS-06A — Paystack Client Boundary

Entry condition:

- VS-05A merged on `main` with admin/internal-pilot entrypoints calling
  `Checkout.start_checkout/3`.
- VS-05 checkout core and VS-05A adapter tests remain green.
- Paystack integration remains a separate boundary module; do not wire payment
  initialization into entrypoint LiveViews until VS-06B.
