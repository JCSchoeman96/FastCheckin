# VS-12 Implementation Handoff

## Status

Merged.

PR: #387 — feat(sales): add VS-12 admin sales dashboard  
Merge commit: `40ec171937a3d653a1168511008e30cccbafae80`  
Merged at: 2026-06-21T16:19:21Z  
Branch: `vs-12-admin-sales-dashboard`

## What Changed

VS-12 added an authenticated, read-only Admin Sales Dashboard at `/dashboard/sales`.
A bounded read-model module (`FastCheck.Sales.AdminDashboard`) aggregates safe Sales
summaries, recent orders, manual-review queue rows, capped inventory health, and
read-only order detail. The LiveView renders masked buyer contact fields, narrow
PaymentEvent status counts, and no destructive operator controls.

No migrations, PubSub, polling, Oban, Paystack/provider calls, issuer/scanner/mobile
changes, Android changes, Redis mutation, or durable write paths were added.

## Files Changed

- `lib/fastcheck/sales/admin_dashboard.ex` — read-only Sales admin query boundary;
  safe display maps only; bounded filters, windows, limits, masking, and inventory
  health via `FastCheck.Sales.Inventory.Health`.
- `lib/fastcheck_web/live/sales_dashboard_live.ex` — authenticated LiveView for
  `/dashboard/sales`; filter form, summary cards, recent orders, manual-review queue,
  inventory table, and read-only order detail panel.
- `lib/fastcheck_web/router.ex` — registers `live "/dashboard/sales", SalesDashboardLive, :index`
  under the existing `[:browser, :dashboard_auth]` scope.
- `test/fastcheck/sales/admin_dashboard_test.exs` — domain tests for bounded windows,
  filters, masking/redaction, manual-review rows, PaymentEvent count summaries, and
  absence of sensitive fields.
- `test/fastcheck_web/sales_dashboard_live_test.exs` — LiveView auth redirect, safe
  rendering, filter allowlist, order detail selection, and absence of destructive
  controls/sensitive HTML.
- `test/fastcheck/sales/domain_shell_test.exs` — Sales file inventory includes
  `admin_dashboard.ex`.
- `test/support/sales_boundary_allowlist.ex` — allowlists
  `lib/fastcheck_web/live/sales_dashboard_live.ex` for Sales boundary checks.
- `test/fastcheck/tickets/ticket_token_boundary_test.exs` — unrelated boundary test
  header adjustment only (no ticket-module behavior change from VS-12).

Planning context (not implementation truth): `docs/fastcheck_sales/feature_packs/0032_VS-12_admin-sales-dashboard/VS-12-FEATURE_PACK.md`.

## Contracts Now Available

- `FastCheck.Sales.AdminDashboard` is the authoritative read-model entrypoint for
  admin Sales visibility.
- Public functions:
  - `summary/1` — bounded KPI counts for the active date window.
  - `recent_orders/2` — safe order list with enrichment (payment, checkout, ticket counts).
  - `manual_review_queue/2` — bounded review rows derived from order/payment/checkout/ticket review states.
  - `order_detail/1` — `{:ok, detail}` or `{:error, :not_found}` for one safe order summary.
  - `inventory_summary/2` — capped offer rows with read-only inventory health from `Health.offer_health/1`.
- Route: authenticated `GET /dashboard/sales` via `FastCheckWeb.SalesDashboardLive`.
- Default query bounds:
  - list limit default `25`, max `100`
  - inventory limit max `25`
  - date window default `30` days, max `90` days
- Allowed filters (domain + LiveView form):
  `event_id`, `search` (public-reference prefix only), `status`, `source_channel`,
  `payment_status`, `from_date`, `to_date`
- Buyer display redaction:
  - name → `"Buyer"`
  - email → first local char + `***@domain`
  - phone → `***` + last four digits
- PaymentEvent exposure is count-by-`processing_status` only for the latest visible
  payment's `provider_reference`; raw payloads and provider secrets are not returned.
- Manual-review queue rows include `reason_code`, status summaries, masked buyer fields,
  and a static `recommended_action` string (no workflow action).

## Decisions Applied

- Read-only dashboard; triage/visibility only, no operator mutations.
- Extend existing dashboard auth shell (`[:browser, :dashboard_auth]`), not a new admin app.
- Direct Ecto read queries on Sales tables for dashboard aggregation; no new Ash workflow actions.
- Inventory visibility through approved `FastCheck.Sales.Inventory.Health` only; no direct Redis key reads/mutations from the dashboard path.
- Search is public-reference prefix only; buyer email/phone search is intentionally not supported.
- Invalid/unknown filter keys are ignored at the LiveView layer; invalid dates/search do not broaden results.
- `event_scoped_first`; `organization_id` deferred.
- Integer cents for money fields in summaries (`amount_cents`).
- VS-21A redaction posture preserved for buyer contact and payment/ticket secret material.

## Boundaries Still Enforced

- No refund, revoke, resend, mark-paid, issue-ticket, release-inventory, or resolve-review controls.
- No manual-review resolution workflow (VS-13).
- No checkout expiry/cleanup automation (VS-14).
- No Paystack calls, webhook/verify mutation, or provider payload rendering.
- No `FastCheck.Tickets.Issuer` changes or ticket issuance triggers from the dashboard.
- No Attendee, Order, PaymentAttempt, PaymentEvent, TicketIssue, or inventory ledger mutation from dashboard code paths.
- No scanner (`FastCheck.Attendees.Scan`) or mobile sync controller/DTO changes.
- No Android changes.
- No PubSub live refresh, polling loops, or Oban jobs added for dashboard updates.
- No new migrations or Ash policies introduced in this slice.
- No customer secure ticket page (`GET /t/:token`) behavior changes.

## Tests Added Or Updated

- `test/fastcheck/sales/admin_dashboard_test.exs` — summary window bounds; recent-order
  limit/order/search/masking; invalid date safety; manual-review queue redaction and
  PaymentEvent count summaries; order detail safe linkage counts; sensitive-value scan
  across results.
- `test/fastcheck_web/sales_dashboard_live_test.exs` — unauthenticated redirect to login;
  authenticated empty dashboard render; safe masked HTML; order detail panel; filter
  allowlist/unknown-key ignore; invalid order selection; forbidden destructive-control text.
- `test/fastcheck/sales/domain_shell_test.exs` — includes `admin_dashboard.ex` in Sales inventory.
- `test/support/sales_boundary_allowlist.ex` — allowlists `sales_dashboard_live.ex`.
- `test/fastcheck/tickets/ticket_token_boundary_test.exs` — header-only adjustment.

## Verification Reported

From PR #387:

```bash
mix compile --warnings-as-errors
mix test test/fastcheck/sales/admin_dashboard_test.exs test/fastcheck_web/sales_dashboard_live_test.exs
mix test test/fastcheck_web/sales/ test/fastcheck/sales/payments/ test/fastcheck/sales/inventory/ test/fastcheck/tickets/ test/fastcheck_web/controllers/mobile/sync_controller_test.exs test/fastcheck/attendees/scan_test.exs test/fastcheck/attendees/reconciliation_test.exs
mix test
mix precommit
```

Results reported at merge:

- targeted domain + LiveView tests — pass
- broader Sales/payment/inventory/ticket/mobile/attendee regression set — pass
- `mix test` — 817 tests, 0 failures, 4 skipped
- `mix precommit` — 817 tests, 0 failures, 4 skipped

## Known Limitations

- Dashboard is snapshot-on-load only; no PubSub/polling refresh.
- Manual-review rows show guidance text but cannot be acted on here (VS-13).
- No refund/revoke/resend/mark-paid/issue/release/resolve operator workflows.
- No raw PaymentEvent payloads, webhook bodies, authorization URLs, access codes, token
  hashes, ticket codes, or idempotency keys in API/HTML output.
- Inventory section is capped and read-only; failures degrade to safe status labels.
- No dedicated slice doc under `docs/fastcheck_sales/slices/`; feature pack is planning context only.
- Internal read queries bypass Ash policy actions; future hardening may introduce explicit system-actor reads if needed.

## Next Agent Guidance

**Reuse:**

- `FastCheck.Sales.AdminDashboard` for all admin Sales read aggregation; do not duplicate
  order/payment/ticket/inventory summary SQL in LiveViews or controllers.
- `FastCheckWeb.SalesDashboardLive` and route `/dashboard/sales` for operator visibility.
- Existing masking helpers/patterns in `AdminDashboard` for any new admin read surfaces.
- `Health.offer_health/1` for inventory health display; do not read Redis keys directly.
- Filter allowlist pattern in `SalesDashboardLive.allowed_filters/1` when extending UI filters.

**Do not:**

- Add destructive buttons or mutation handlers to VS-12 dashboard files without an approved later slice.
- Return or render raw buyer email/phone, Paystack payloads, ticket codes, token hashes, or idempotency keys.
- Broaden search to buyer contact fields without an explicit security/contract change.
- Bypass `AdminDashboard` from VS-13+ operator workflows; extend or add sibling modules instead.
- Change scanner/mobile/secure-ticket-page contracts from dashboard work.

**Keep green:**

- `test/fastcheck/sales/admin_dashboard_test.exs`
- `test/fastcheck_web/sales_dashboard_live_test.exs`
- `test/fastcheck_web/sales/`
- `test/fastcheck/sales/payments/`
- `test/fastcheck/sales/inventory/`
- `test/fastcheck/tickets/`
- `test/fastcheck_web/controllers/mobile/sync_controller_test.exs`
- `test/fastcheck/attendees/scan_test.exs`
- `test/fastcheck/attendees/reconciliation_test.exs`
- `mix precommit`

## Next Slice

Recommended next slice: **VS-13 — Manual Review Operations**

Entry condition:

- VS-12 is merged on `main`.
- `/dashboard/sales` and `FastCheck.Sales.AdminDashboard` remain the read-only visibility contract.
- Manual-review queue visibility exists but has no resolution actions yet.
- Payment verification, issuance, secure ticket page, and mobile sync boundaries from VS-07/VS-09/VS-10/VS-11 remain unchanged.
- VS-13 should add the first bounded operator workflow for `manual_review` cases with audit logging, not a generic admin override console.
