# VS-21B Implementation Handoff

## Status

Merged.

PR: #408 — [codex] feat(sales): add VS-21B operational metrics views  
Merge commit: `0c0f71c040d0a75df4f9eb6582428cff2436d220`  
Merged at: 2026-06-27T13:23:25Z  
Branch: `vs-21b-operational-metrics-audit-views`

## What Changed

VS-21B added read-only Sales operational visibility: bounded Postgres query modules,
dashboard-auth LiveViews, Sales telemetry metric definitions, and query-path indexes.

`FastCheck.Sales.OpsMetrics` returns safe display maps for checkout/payment/ticket/
delivery/manual-review pressure, scanner-visibility invalidation counts, and Oban
retry backlog. `FastCheck.Sales.AuditViews` returns allowlisted, paginated, redacted
audit timelines from `sales_state_transitions` plus entity-specific summary rows.

Routes `/dashboard/sales/ops` and `/dashboard/sales/audit/:entity_type/:entity_id`
live under the existing `[:browser, :dashboard_auth]` scope.

No provider calls, ticket issuing, scanner mutation, Redis inventory mutation,
checkout/order/payment/ticket transitions, Android/mobile API changes, new Ash
resources, dashboard cache, polling, PubSub refresh, or raw payload viewer were added.

## Files Changed

- `lib/fastcheck/sales/ops_metrics.ex` — read-only operational aggregates and
  `recent_failures/2`; bounded windows (`15m`, `1h`, `24h`, `7d`), filters
  (`event_id`, `source_channel`), default limit 25 / max 50.
- `lib/fastcheck/sales/audit_views.ex` — allowlisted entity timelines with DB-level
  pagination; summary rows on page 1 only; metadata redacted via
  `FastCheck.Observability.Redactor`.
- `lib/fastcheck_web/live/sales/ops_dashboard_live.ex` — read-only ops dashboard;
  filter form; links to audit timelines for recent payment failures.
- `lib/fastcheck_web/live/sales/audit_timeline_live.ex` — read-only audit timeline
  LiveView for allowed entity types.
- `lib/fastcheck_web/router.ex` — registers ops and audit LiveView routes under
  dashboard auth.
- `lib/fastcheck_web/telemetry.ex` — Sales counter metric definitions with
  low-cardinality tags only (`:status`, `:source_channel`, `:provider`,
  `:reason_code`, `:queue`, etc.).
- `priv/repo/migrations/20260627110000_add_sales_ops_query_indexes.exs` — query-path
  indexes for ops/audit reads; does not make `TicketIssue.scanner_status` scanner
  authority.
- `test/fastcheck/sales/ops_metrics_test.exs` — bounded counters, capped failures,
  redaction boundary.
- `test/fastcheck/sales/audit_views_test.exs` — entity allowlist, DB pagination,
  summary-vs-transition pagination split, redaction.
- `test/fastcheck_web/live/sales/ops_dashboard_live_test.exs` — dashboard auth,
  safe HTML, no mutation affordances.
- `test/fastcheck_web/live/sales/audit_timeline_live_test.exs` — audit auth and
  redacted timeline rendering.
- `test/fastcheck_web/telemetry_sales_metrics_test.exs` — Sales metrics exist; no
  forbidden high-cardinality tags.
- `test/fastcheck/sales/vs_01g_index_and_migration_verification_test.exs` — asserts
  VS-21B migration indexes.
- `test/fastcheck/sales/domain_shell_test.exs` — registers new Sales modules in
  domain shell inventory.
- `test/support/sales_boundary_allowlist.ex` — VS-21B slice boundary allowlist.

## Contracts Now Available

- `FastCheck.Sales.OpsMetrics.summary/1` — bounded operational counter map for a
  time window and optional `event_id` / `source_channel` filters.
- `FastCheck.Sales.OpsMetrics.recent_failures/2` — capped, newest-first payment-
  attempt failure rows with safe display fields only.
- `FastCheck.Sales.AuditViews.timeline/3` — `{:ok, %{entries:, page:, limit:,
  next_page:}}` or `{:error, :invalid_entity_type | :invalid_entity_id}` for
  allowlisted `entity_type` strings: `order`, `checkout_session`, `payment_attempt`,
  `payment_event`, `ticket_issue`, `delivery_attempt`, `conversation`,
  `state_transition`, `attendee_invalidation_event`.
- `FastCheckWeb.Sales.OpsDashboardLive` at `GET /dashboard/sales/ops` — requires
  dashboard auth; read-only.
- `FastCheckWeb.Sales.AuditTimelineLive` at
  `GET /dashboard/sales/audit/:entity_type/:entity_id` — requires dashboard auth;
  read-only.
- `FastCheckWeb.Telemetry.metrics/0` — includes `fastcheck.sales.*` counter
  definitions (checkout, payment, ticket, delivery, manual review, inventory,
  WhatsApp, admin revocation/refund groups).
- Migration indexes: `sales_orders_source_status_inserted_at_idx`,
  `sales_orders_status_inserted_at_idx`, `sales_payment_attempts_status_inserted_at_idx`,
  `sales_ticket_issues_status_inserted_at_idx`,
  `sales_delivery_attempts_status_inserted_at_idx`,
  `sales_delivery_attempts_ticket_issue_inserted_at_idx`,
  `sales_delivery_attempts_order_inserted_at_idx`,
  `sales_conversations_state_needs_human_last_message_at_idx`.
- Scanner visibility pending count reads `attendee_invalidation_events`, not
  `TicketIssue.scanner_status`.

## Decisions Applied

- Read-only visibility slice; no workflow actions or mutation endpoints.
- Reuse `FastCheck.Observability.Redactor` for audit timeline metadata and safe
  display shaping.
- Extend existing `FastCheckWeb.Telemetry` metric list; no second metrics supervisor.
- Routes under existing `[:browser, :dashboard_auth]` boundary.
- Bounded query windows and pagination limits enforced in code.
- Summary audit rows render on page 1 only and do not consume transition pagination
  budget.
- `TicketIssue.scanner_status` is not treated as scanner authority; invalidation
  events remain the visibility signal for ops counts.
- No `admin_audit.ex`, `cached_metrics.ex`, Cachex/Redis aggregate cache, or PubSub
  dashboard refresh in this slice.

## Boundaries Still Enforced

- No Paystack verification/refund API calls.
- No Meta/WhatsApp outbound sends or inbound webhook handling.
- No ticket issuing, attendee/scanner mutation, or Redis inventory mutation.
- No checkout/order/payment/ticket state transitions from ops or audit views.
- No raw provider payload inspection UI.
- No Android/mobile API or scanner runtime changes.
- No new Ash resources or policies.
- No dashboard polling, PubSub refresh wiring, or cached aggregate layer.
- No Sentry alert routing or Prometheus exporter changes beyond metric definitions.

## Tests Added Or Updated

- `test/fastcheck/sales/ops_metrics_test.exs` — windowed counters, capped
  `recent_failures`, no PII/token/url leakage in results.
- `test/fastcheck/sales/audit_views_test.exs` — entity allowlist, newest-first
  ordering, LIMIT/OFFSET pagination, summary rows outside pagination budget,
  redacted metadata.
- `test/fastcheck_web/live/sales/ops_dashboard_live_test.exs` — unauthenticated
  redirect, authenticated safe dashboard, no mutation buttons.
- `test/fastcheck_web/live/sales/audit_timeline_live_test.exs` — unauthenticated
  redirect, redacted timeline HTML.
- `test/fastcheck_web/telemetry_sales_metrics_test.exs` — Sales metrics registered;
  forbidden tags absent.
- `test/fastcheck/sales/vs_01g_index_and_migration_verification_test.exs` — VS-21B
  index assertions.
- `test/fastcheck/sales/domain_shell_test.exs` — module inventory update.
- `test/support/sales_boundary_allowlist.ex` — VS-21B boundary registration.

Regression suites exercised at merge (must stay green):

- `test/fastcheck/sales/admin_dashboard_test.exs`
- `test/fastcheck_web/sales_dashboard_live_test.exs`
- `test/fastcheck/sales/manual_review_test.exs`
- `test/fastcheck_web/sales_manual_review_live_test.exs`
- `test/fastcheck/sales/admin_refunds_test.exs`
- `test/fastcheck/sales/admin_revocations_test.exs`
- `test/fastcheck_web/live/sales/order_show_live_test.exs`
- `test/fastcheck/tickets/revocation_test.exs`
- `test/fastcheck/tickets/revocation_boundary_test.exs`
- `test/fastcheck/observability/`

## Verification Reported

From PR #408:

```bash
mix compile --warnings-as-errors
mix test test/fastcheck/sales/ops_metrics_test.exs
mix test test/fastcheck/sales/audit_views_test.exs
mix test test/fastcheck_web/live/sales/ops_dashboard_live_test.exs test/fastcheck_web/live/sales/audit_timeline_live_test.exs test/fastcheck_web/telemetry_sales_metrics_test.exs
mix test test/fastcheck/sales/ops_metrics_test.exs test/fastcheck/sales/audit_views_test.exs test/fastcheck_web/live/sales/ops_dashboard_live_test.exs test/fastcheck_web/live/sales/audit_timeline_live_test.exs test/fastcheck_web/telemetry_sales_metrics_test.exs test/fastcheck/sales/domain_shell_test.exs test/fastcheck/sales/vs_01g_index_and_migration_verification_test.exs
mix test test/fastcheck/sales/admin_dashboard_test.exs test/fastcheck_web/sales_dashboard_live_test.exs test/fastcheck/sales/manual_review_test.exs test/fastcheck_web/sales_manual_review_live_test.exs test/fastcheck/sales/admin_refunds_test.exs test/fastcheck/sales/admin_revocations_test.exs test/fastcheck_web/live/sales/order_show_live_test.exs test/fastcheck/tickets/revocation_test.exs test/fastcheck/tickets/revocation_boundary_test.exs test/fastcheck/observability/
mix test
mix precommit
```

Results reported at merge:

- `mix test` — 1024 tests, 0 failures, 4 skipped
- `mix precommit` — passed; Credo found no issues; 1024 tests, 0 failures, 4 skipped

## Known Limitations

- Sales telemetry metrics are **defined** in `FastCheckWeb.Telemetry`; not every
  Sales workflow module emits all counters yet. Some flows already use
  `TelemetryNames` (e.g. revocation); broad checkout/payment/WhatsApp emission
  wiring may remain incomplete outside this slice.
- No Cachex/Redis warm cache, PubSub live refresh, or `cached_metrics` module.
- No `admin_audit.ex` helper; audit reads live in `AuditViews` only.
- No slice doc under `docs/fastcheck_sales/slices/`; feature pack remains planning
  reference.
- Ops dashboard loads on mount/filter change only; no polling interval.
- `worker_retry_backlog_by_queue/0` returns `%{}` if Oban query fails (rescued).

## Next Agent Guidance

**Reuse:**

- `FastCheck.Sales.OpsMetrics` and `FastCheck.Sales.AuditViews` for any future
  admin/ops read surfaces — do not duplicate bounded query logic.
- `FastCheck.Observability.Redactor` for any new audit or ops display fields.
- Existing dashboard-auth routes and LiveView patterns under
  `lib/fastcheck_web/live/sales/`.
- VS-21B migration indexes for ops/audit query paths.
- `FastCheckWeb.Telemetry` Sales counter definitions when adding
  `:telemetry.execute` calls.

**Do not:**

- Add mutation actions, provider HTTP, ticket issuance, or scanner writes to ops/
  audit modules or LiveViews.
- Treat `TicketIssue.scanner_status` as scanner authority.
- Expose raw payloads, buyer PII, tokens, authorization URLs, or ticket codes in
  ops/audit responses.
- Create a parallel metrics supervisor or high-cardinality telemetry tags.
- Bypass dashboard auth for `/dashboard/sales/ops` or `/dashboard/sales/audit/*`.
- Recreate `admin_audit.ex` or `cached_metrics.ex` without an explicit new slice.

**Authoritative modules:** `OpsMetrics`, `AuditViews`, ops/audit LiveViews,
`FastCheckWeb.Telemetry` Sales metric block, migration
`20260627110000_add_sales_ops_query_indexes.exs`.

**Tests that must remain green:** VS-21B tests above plus admin dashboard, manual
review, refunds/revocations, order show, revocation, and observability suites
listed in this handoff.

## Next Slice

Recommended next slice:
**VS-22 — End-to-End Sandbox Tests**

Entry condition:

- Launch scope is selected (see VS-00D / roadmap).
- VS-21B ops dashboard and audit views are available for launch validation and
  failure-path inspection.
- Prior dependencies for the chosen launch scope are merged (VS-05, VS-06C,
  VS-07C, VS-09D, VS-10, VS-11, VS-14, VS-15A, VS-21A, VS-21B; plus VS-15B and
  VS-16–VS-20 when those are in launch scope).
- Reuse existing `DataCase` / `ConnCase` fixtures and Sales boundary allowlists;
  do not bypass read-only ops/audit redaction rules when asserting operator views.
