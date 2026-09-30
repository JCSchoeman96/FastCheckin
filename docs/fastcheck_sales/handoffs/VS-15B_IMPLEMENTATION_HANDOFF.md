# VS-15B Implementation Handoff

## Status

Merged.

PR: #396 — feat(sales): VS-15B admin refund and revocation operations  
Merge commit: `18d4891d116c4baabef8d5bf532e92af324c4929`  
Implementation head: `5b1130d5c2e08a5ec0222cf55021e81c7a02f377`  
Merged at: 2026-06-25T19:01:03Z  
Branch: `vs-15b-admin-refund-revocation`  
CI: GitHub Actions run 28192438625 green on merge

P1-C supersedes the refund-marker flow described below. Current refunds require
durable processed Paystack evidence, completed ticket revocation, and the
`Order.finalize_refund` / `Refund.mark_inventory_pending` transaction described
in [the P1-C feature pack](../feature_packs/0056_P1-C_durable-refund-evidence/0056_P1-C-FEATURE_PACK.md).
`Order` no longer exposes `:mark_refunded_manual`; cancellation and revocation
remain on the VS-15B path.

## P1-D-REV-01 authority correction

The original VS-15B service contract and test allowed an operator-shaped actor map to revoke one ticket.
That map did not establish operator identity or grant provenance. The current production dashboard
orchestration is admin-only: DashboardAccess resolves the configured dashboard identity and
`DASHBOARD_ALLOWED_EVENT_IDS`. FastCheck.Tickets.Revocation retains `:operator` domain support
for a caller that has already established trusted identity and Event authority. The core does not
authenticate that caller. No production Sales operator entry point currently exists. A future entry point
requires a separate trusted operator-authority design. Track it as FastCheckin-iuaq.

## What Changed

VS-15B added dashboard-admin orchestration for manual order refund/cancel markers and ticket revocation.
P1-D resolves Event grants from the configured admin identity. LiveViews call `AdminRevocations` / `AdminRefunds` — not
`FastCheck.Tickets.Revocation` directly.

`AdminRevocations` wraps VS-15A `Revocation` for single-ticket and order-batch revoke,
revalidates the dashboard identity and server-owned Event grant, requires reason (and bulk confirmation +
admin password for order-level revoke), and emits admin telemetry. Order-batch revoke
returns `{:error, {:revoke_failures, failures}}` when any ticket fails.

`AdminRefunds` revokes issued tickets first via `AdminRevocations`, then transitions
`Order` through Ash `:mark_refunded_manual` or `:mark_cancelled_manual`. Refund/cancel
fail closed when revoke failures exist.

`Sales.OrderShowLive` at `/dashboard/sales/orders/:id` (behind `[:browser,
:dashboard_auth]`) surfaces bounded masked order context and action forms. The sales
dashboard links to it via “Manage order operations”.

`FastCheck.Tickets.Revocation` and `ScannerVisibility` were **not** modified.

Planning context (not implementation truth):
`docs/fastcheck_sales/feature_packs/0036_VS-15B_admin-refund-and-revocation-operations/VS-15B-FEATURE_PACK.md`.

## Files Changed

- `lib/fastcheck/sales/admin_revocations.ex` — dashboard revoke orchestration;
  delegates to `Revocation`; event-scope gate; order-batch failure errors; VS-13
  hold/close delegates.
- `lib/fastcheck/sales/admin_refunds.ex` — order refund/cancel orchestration;
  bounded `get_order_operations_context/2`; revoke-first fail-closed semantics.
- `lib/fastcheck/sales/order.ex` — Ash `:mark_refunded_manual` and
  `:mark_cancelled_manual` (idempotent, admin-only policies, `StateTransition` audit).
- `lib/fastcheck_web/live/sales/order_show_live.ex` — order operations LiveView.
  P1-D supersedes the original target-derived actor construction; the LiveView now resolves
  DashboardAccess from session identity before the scoped order lookup.
- `lib/fastcheck_web/live/sales/components/revocation_form_component.ex` — shared
  reason / bulk-confirm / password form.
- `lib/fastcheck_web/live/sales_dashboard_live.ex` — navigation link to order show.
- `lib/fastcheck_web/router.ex` — `live "/dashboard/sales/orders/:id"`.
- `lib/fastcheck/observability/telemetry_names.ex` — five admin events (27 → 32).
- `test/fastcheck/sales/admin_revocations_test.exs` — admin single/batch revoke, Event-scope denial,
  operator-shaped dashboard actor denial, password/bulk gates, sync-failure passthrough, and missing-
  attendee batch error. The earlier operator success case used a synthetic map and did not prove
  production operator authority.
- `test/fastcheck/sales/admin_refunds_test.exs` — refund/cancel success, scope denial,
  operator-shaped caller denied, verified-payment required, revoke-failure blocking, idempotent
  transition, and bounded context.
- `test/fastcheck_web/live/sales/order_show_live_test.exs` — masked context, revoke
  and refund flows, order-revoke failure surfaces blocking error (not success).
- `test/support/admin_refund_fixtures.ex` — issued-order and scoped-actor fixtures.
- `test/support/sales_boundary_allowlist.ex` — `@vs_15b_allowed_prefixes`.
- `test/fastcheck/sales/domain_shell_test.exs`, `telemetry_names_test.exs` — shell /
  telemetry count updates only.

## Contracts Now Available

- `FastCheck.Sales.AdminRevocations.revoke_ticket_issue/3` — current dashboard single-ticket revoke.
  It accepts the configured admin identity and server-owned Event grants, requires a reason, and
  checks the Order Event.
- `FastCheck.Tickets.Revocation.revoke_ticket_issue/2` — core domain operation retains
  `:operator` support when an upstream caller has established trusted identity and Event scope.
  The core does not authenticate callers.
- `FastCheck.Sales.AdminRevocations.revoke_order_tickets/3` — admin-only order-batch
  revoke; requires `confirmed_bulk`, `admin_password`, and event scope; returns
  `{:error, {:revoke_failures, failures}}` on partial failure.
- `FastCheck.Sales.AdminRefunds.mark_order_refunded_manual/3` and
  `mark_order_cancelled_manual/3` — order-level manual markers after revoke; return
  `{:error, {:revoke_failures, _}}` when revoke fails.
- `FastCheck.Sales.AdminRefunds.get_order_operations_context/2` — bounded masked
  order + ticket summaries for LiveView (limit capped at 25).
- `Order` Ash `:mark_refunded_manual` / `:mark_cancelled_manual` — durable order state
  with idempotent retry (no duplicate `StateTransition` when already terminal).
- Route `GET /dashboard/sales/orders/:id` → `Sales.OrderShowLive` under dashboard auth.
- Admin telemetry events: `admin_revocation_requested`, `admin_revocation_completed`,
  `admin_revocation_failed`, `admin_refund_marked`, `admin_action_denied`.

## Decisions Applied

- VS-15B production dashboard orchestration is configured-admin-only. VS-15A Revocation remains the
  scanner-safety authority and retains core operator domain support.
- Order-level refund/cancel only (no per-ticket refund marker API).
- Revoke-before-refund/cancel; fail closed on revoke failures.
- Dashboard service boundaries re-resolve identity through DashboardAccess and use server-configured
  Event grants; route and record IDs never create authority. The configured dashboard identity maps to admin.
- Order-level revoke failures are service errors (`{:revoke_failures, _}`), not UI
  success.
- Sensitive actions use `BrowserAuth.valid_admin_password?/1`.
- Mandatory `reason` on mutating actions.
- `event_scoped_first`; `organization_id` deferred.
- Telemetry/logs use `Redactor` / operational metadata; buyer PII masked in UI.

## Boundaries Still Enforced

- No Paystack refund API or automated payment reversal.
- No per-ticket manual refund marker.
- No changes to `FastCheck.Tickets.Revocation` or `ScannerVisibility`.
- No scanner/mobile API or Android client changes.
- No Redis inventory mutation.
- No WhatsApp/Meta/delivery workflow changes in this slice.
- No new migrations.
- Operator cannot order-batch revoke, mark refunded, or mark cancelled (admin-only).
- No multi-event RBAC beyond `allowed_event_ids` on the service actor.

## Tests Added Or Updated

- `test/fastcheck/sales/admin_revocations_test.exs` — admin single/batch revoke, Event-scope denial,
  operator-shaped dashboard actor denial, password/bulk gates, sync-failure passthrough, and missing-
  attendee batch error. The earlier operator success case used a synthetic map and did not prove
  production operator authority.
- `test/fastcheck/sales/admin_refunds_test.exs` — refund/cancel success, scope denial,
  operator-shaped caller denied, verified-payment required, revoke-failure blocking, idempotent
  transition, and bounded context.
- `test/fastcheck_web/live/sales/order_show_live_test.exs` — auth redirect, masked
  HTML, ticket revoke, mark refunded, order-revoke failure error messaging.
- `test/support/admin_refund_fixtures.ex` — shared issued-order fixture and scoped
  actors.
- `telemetry_names_test.exs`, `domain_shell_test.exs`, `sales_boundary_allowlist.ex` —
  registration/allowlist only.

## Verification Reported

From PR #396 test plan and merge CI:

```bash
mix test test/fastcheck/sales/admin_revocations_test.exs
mix test test/fastcheck/sales/admin_refunds_test.exs
mix test test/fastcheck_web/live/sales/order_show_live_test.exs
mix test test/fastcheck/tickets/revocation_test.exs test/fastcheck/tickets/revocation_boundary_test.exs
mix precommit
```

Results reported:

- Targeted VS-15B + revocation regression tests — 0 failures
- `mix precommit` — 915 tests, 0 failures
- CI run 28192438625 — success on merge

## Known Limitations

- No trusted production Sales operator identity/Event-authority boundary or operator revocation entry
  point exists. The core operator capability is not exposed through the dashboard.
- Manual order refunded / cancelled markers only; no Paystack refund orchestration.
- Dashboard auth uses one configured identity and a server-owned Event grant list; it does not yet have
  per-user membership or multi-admin RBAC.
- `AdminRevocations.invoke_order_ticket_revocation/2` normalizes some VS-15A batch
  `{:error, :rollback}` / `{:missing_attendee, _}` outcomes into failure collections
  at the admin layer (Revocation module unchanged).
- Hold/close actions on order show delegate to VS-13 `ManualReview`; no new manual-
  review queue UI beyond existing VS-13 surfaces.
- No dedicated Oban worker; synchronous service calls only.

## Next Agent Guidance

**Reuse:**

- `AdminRevocations` / `AdminRefunds` from LiveView and future admin APIs — do not
  call `Revocation` directly from UI.
- Resolve dashboard actors through DashboardAccess; never pass a target-derived or caller-supplied
  grant as authority.
- `get_order_operations_context/2` for bounded read models on order show pages.
- VS-15A Revocation for all scanner-visible ticket mutation. Its `:operator` domain capability
  requires trusted upstream authority; do not expose it through an unverified map.
- VS-13 `ManualReview` for hold/close investigation flows.

**Do not:**

- Bypass admin services to Ash-update `TicketIssue` or `Attendee` from dashboard code.
- Mark orders refunded/cancelled without going through revoke-first orchestration.
- Treat `{:ok, %{failures: [_ | _]}}` from a direct `revoke_order_tickets/3` call as
  success (public API returns `{:error, {:revoke_failures, _}}`).
- Add Paystack refund calls to `AdminRefunds`.
- Modify `Revocation` / `ScannerVisibility` for admin UI concerns.

**Keep green:**

- `test/fastcheck/sales/admin_revocations_test.exs`
- `test/fastcheck/sales/admin_refunds_test.exs`
- `test/fastcheck_web/live/sales/order_show_live_test.exs`
- `test/fastcheck/tickets/revocation_test.exs`
- `test/fastcheck/tickets/revocation_boundary_test.exs`
- `mix precommit`

## Next Slice

Recommended next slice: **VS-16 — Meta Cloud API Outbound Client**

Entry condition:

- VS-15B merged on `main`; admin refund/revocation orchestration available.
- VS-00B security/token policies remain the authority for outbound messaging secrets.
- VS-16 is WhatsApp/provider work — do not fold Meta client logic into
  `AdminRevocations`, `AdminRefunds`, or `Revocation`.
