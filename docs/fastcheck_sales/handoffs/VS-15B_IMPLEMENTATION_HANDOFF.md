# VS-15B Implementation Handoff

## Status

Merged.

PR: #396 — feat(sales): VS-15B admin refund and revocation operations  
Merge commit: `18d4891d116c4baabef8d5bf532e92af324c4929`  
Implementation head: `5b1130d5c2e08a5ec0222cf55021e81c7a02f377`  
Merged at: 2026-06-25T19:01:03Z  
Branch: `vs-15b-admin-refund-revocation`  
CI: GitHub Actions run 28192438625 green on merge

## What Changed

VS-15B added dashboard admin orchestration for manual order refund/cancel markers and
ticket revocation. LiveViews call `AdminRevocations` / `AdminRefunds` — not
`FastCheck.Tickets.Revocation` directly.

`AdminRevocations` wraps VS-15A `Revocation` for single-ticket and order-batch revoke,
enforces `actor_type` + `allowed_event_ids`, requires reason (and bulk confirmation +
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
- `lib/fastcheck_web/live/sales/order_show_live.ex` — order operations LiveView;
  builds actor with `allowed_event_ids: [context.event_id]`.
- `lib/fastcheck_web/live/sales/components/revocation_form_component.ex` — shared
  reason / bulk-confirm / password form.
- `lib/fastcheck_web/live/sales_dashboard_live.ex` — navigation link to order show.
- `lib/fastcheck_web/router.ex` — `live "/dashboard/sales/orders/:id"`.
- `lib/fastcheck/observability/telemetry_names.ex` — five admin events (27 → 32).
- `test/fastcheck/sales/admin_revocations_test.exs` — revoke auth, scope, password,
  sync-failure passthrough, missing-attendee `revoke_failures` error.
- `test/fastcheck/sales/admin_refunds_test.exs` — refund/cancel happy path, scope
  denial, verified-payment gate, revoke-failure blocking, idempotency.
- `test/fastcheck_web/live/sales/order_show_live_test.exs` — masked context, revoke
  and refund flows, order-revoke failure surfaces blocking error (not success).
- `test/support/admin_refund_fixtures.ex` — issued-order and scoped-actor fixtures.
- `test/support/sales_boundary_allowlist.ex` — `@vs_15b_allowed_prefixes`.
- `test/fastcheck/sales/domain_shell_test.exs`, `telemetry_names_test.exs` — shell /
  telemetry count updates only.

## Contracts Now Available

- `FastCheck.Sales.AdminRevocations.revoke_ticket_issue/3` — single-ticket revoke
  (admin or in-scope operator); requires `reason` and `order.event_id in
  actor.allowed_event_ids`.
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

- VS-15B is admin orchestration only; VS-15A `Revocation` remains scanner-safety
  authority.
- Order-level refund/cancel only (no per-ticket refund marker API).
- Revoke-before-refund/cancel; fail closed on revoke failures.
- Service-layer `actor_type` + non-empty `allowed_event_ids` required; services do not
  inject scope the caller lacks. LiveView maps single dashboard credential to admin
  with `allowed_event_ids: [order.event_id]`.
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

- `test/fastcheck/sales/admin_revocations_test.exs` — single/batch revoke, scope
  denial, operator single-ticket success, operator bulk forbidden, password/bulk
  gates, sync aggregation failure passthrough, missing-attendee batch error.
- `test/fastcheck/sales/admin_refunds_test.exs` — refund/cancel success, scope
  denial, operator forbidden, verified-payment required, revoke-failure blocking,
  idempotent refunded transition, bounded context.
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

- Manual order `refunded` / `cancelled` markers only; no Paystack refund orchestration.
- Dashboard auth is still a single credential; event scope is assigned per order page,
  not full multi-admin RBAC.
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
- Pass actors with explicit `allowed_event_ids` matching the target order’s `event_id`.
- `get_order_operations_context/2` for bounded read models on order show pages.
- VS-15A `Revocation` for all scanner-visible ticket mutation.
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
