# FastCheck Sales Feature Planning Pack — VS-21B Operational Metrics and Audit Views

**Pack ID:** `0043_VS-21B_operational-metrics-and-audit-views`  
**Slice:** `VS-21B`  
**Slice name:** Operational Metrics and Audit Views  
**Version:** `v1.0`  
**Date:** 2026-06-13  
**Status:** Implementation-ready planning pack  
**Primary area:** Observability / Admin / Audit / Metrics  
**Repo truth:** `JCSchoeman96/FastCheckin`  
**Repository path:** `docs/fastcheck_sales/feature_packs/0043_VS-21B_operational-metrics-and-audit-views/`  
**Source docs:** `docs/fastcheck_sales/SOURCE_DOCS/FastCheck_Sales_Ash_Atlas_Planning_Pack_v0.2.3_HARDENED.md`, `docs/fastcheck_sales/SOURCE_DOCS/FastCheck_Sales_Vertical_Slice_Roadmap_v1.1.3_HARDENED.md`  
**Depends on:** VS-07C, VS-09D, VS-12, VS-21A  
**Strongly benefits from:** VS-13, VS-14, VS-15A, VS-15B, VS-20  
**Blocks:** VS-22, VS-23B, production launch hardening  

---

## 1. Purpose

Add operational visibility for the FastCheck Sales system without creating new business authority.

VS-21B turns the VS-21A naming/redaction foundation into useful support and launch dashboards:

```text
sales health overview
checkout/payment/ticket/delivery counters
manual-review and failure queues
recent StateTransition audit views
safe DeliveryAttempt audit visibility
safe PaymentEvent/PaymentAttempt summaries
revocation/scanner-visibility audit visibility
bounded filters and paginated list views
```

This slice must be read-first and audit-first.

It must not introduce payment verification, refund logic, ticket issuing, scanner mutation, WhatsApp sending, or inventory mutation.

Repo-alignment guardrail:

```text
Do not add attendees.scanner_status.
Existing scanner/mobile truth remains FastCheck.Attendees.Attendee.scan_eligibility with ineligibility_reason and ineligible_since.
Sales TicketIssue status may be used for Sales audit views only; it must not become the scanner authority.
```

---

## 2. FastCheckin Repo Truth

Use existing FastCheckin conventions:

```text
Telemetry module: FastCheckWeb.Telemetry
Admin dashboard pattern: FastCheckWeb.DashboardLive
Auth boundary: FastCheckWeb.Plugs.BrowserAuth and router [:browser, :dashboard_auth]
Request metadata: FastCheckWeb.Plugs.LoggerMetadata
Sentry redaction: FastCheckWeb.SentryFilter
Mailer boundary: FastCheck.Mailer if delivery views link to fallback state only
Redis boundary: FastCheck.Redis.Connection / FastCheck.Redix if cached counters are introduced
```

Existing telemetry currently covers Phoenix, Repo, scanner, mobile sync, and VM metrics. VS-21B should extend the existing metrics list rather than creating a second metrics supervisor.

---

## 3. Ultimate Outcome

After VS-21B, operators/admins can answer these questions quickly:

```text
Are checkouts being created and expiring normally?
Are Paystack webhooks arriving and being verified?
Are there amount/currency/reference mismatches?
Are ticket issuance retries succeeding?
Are any orders stuck in manual_review, partially_issued, payment_pending, or fulfillment_queued?
Are revocations scanner-visible?
Are WhatsApp/email delivery attempts failing or needing fallback?
What happened to this order/ticket/payment according to StateTransition audit?
```

The implementation must remain safe under live-event load:

```text
No large table scans.
No raw provider payload dumping.
No customer token exposure.
No per-row N+1 dashboard queries.
No mutations from metrics views except explicit links to existing VS-13/VS-15B actions where already implemented.
```

---

## 4. Scope

### In scope

```text
Add Sales telemetry metrics to FastCheckWeb.Telemetry.
Create read-only operational query module(s).
Create bounded admin audit views for orders, payments, ticket issues, delivery attempts, manual review, and state transitions.
Create safe counters and status summaries.
Add indexes/materialized-view recommendations where query paths need them.
Add optional Cachex/Redis cached aggregate layer for high-read dashboard counters.
Add tests proving PII/raw-payload/token redaction in views.
Add tests proving pagination and indexed query paths.
Add tests proving no business mutations occur from dashboard read views.
```

### Out of scope

```text
No Paystack verification logic.
No Paystack refund API calls.
No Meta API sends.
No WhatsApp inbound/outbound state transitions.
No ticket issuing.
No attendee/scanner mutation.
No Redis inventory mutation.
No checkout creation/expiry mutation.
No admin manual-review operation implementation beyond links to existing approved routes/actions.
No new provider webhooks.
```

---

## 5. Recommended Files

```text
lib/fastcheck/sales/ops_metrics.ex
lib/fastcheck/sales/audit_views.ex
lib/fastcheck/sales/admin_audit.ex
lib/fastcheck/sales/cached_metrics.ex              # optional if Cachex/Redis aggregate layer is needed
lib/fastcheck_web/live/sales/ops_dashboard_live.ex
lib/fastcheck_web/live/sales/audit_timeline_live.ex
lib/fastcheck_web/telemetry.ex
lib/fastcheck/observability/telemetry_names.ex
lib/fastcheck/observability/redactor.ex

priv/repo/migrations/*_add_sales_ops_query_indexes.exs
priv/repo/migrations/*_add_sales_ops_materialized_views.exs  # optional; only if justified

test/fastcheck/sales/ops_metrics_test.exs
test/fastcheck/sales/audit_views_test.exs
test/fastcheck_web/live/sales/ops_dashboard_live_test.exs
test/fastcheck_web/live/sales/audit_timeline_live_test.exs
test/fastcheck_web/telemetry_sales_metrics_test.exs
```

Use the existing `FastCheckWeb.DashboardLive` and `FastCheckWeb.OccupancyLive` conventions for LiveView style, but keep Sales dashboards in `FastCheckWeb.Sales.*` or `FastCheckWeb.Live.Sales.*` according to the pattern accepted in VS-12.

---

## 6. Route Plan

Add routes only under dashboard auth:

```elixir
scope "/", FastCheckWeb do
  pipe_through [:browser, :dashboard_auth]

  live "/dashboard/sales/ops", Sales.OpsDashboardLive, :index
  live "/dashboard/sales/audit/:entity_type/:entity_id", Sales.AuditTimelineLive, :show
end
```

If VS-12 already created `/dashboard/sales`, prefer adding nested tabs/routes under that surface instead of adding duplicate navigation.

Rules:

```text
No public routes.
No customer_session access.
No unauthenticated access.
No raw provider payload route in this slice.
```

---

## 7. Operational Metrics Contract

### 7.1 Counters and gauges

Minimum metrics/counters:

```text
orders_by_status
orders_by_source_channel
checkout_sessions_by_status
checkout_expiring_soon_count
checkout_expired_unreleased_count
payment_attempts_by_status
payment_mismatch_count
payment_unmatched_event_count
payment_webhook_duplicate_count
tickets_issued_count
tickets_partially_issued_count
ticket_issue_failure_count
tickets_revoked_count
scanner_visibility_pending_count
delivery_attempts_by_status
delivery_fallback_required_count
manual_review_open_count
manual_review_oldest_age_seconds
worker_retry_backlog_by_queue
```

### 7.2 Time windows

Support bounded windows only:

```text
last 15 minutes
last 1 hour
last 24 hours
last 7 days
specific event_id
specific source_channel
specific status
```

Avoid unbounded “all history” queries on hot dashboards.

### 7.3 Freshness targets

```text
Dashboard headline counters: 5–30 seconds stale is acceptable.
Manual review queue: 5–30 seconds stale is acceptable.
Audit timeline for a selected order/ticket: read from Postgres directly with pagination.
Payment/delivery failure counters: 10–60 seconds stale is acceptable unless incident mode is added later.
```

---

## 8. Audit View Contract

Create safe audit timeline views for:

```text
Order
CheckoutSession
PaymentAttempt
PaymentEvent summary
TicketIssue
DeliveryAttempt
Conversation
StateTransition
AttendeeInvalidationEvent summary for Sales-created tickets
```

Each timeline row should include:

```text
timestamp
entity_type
entity_id
state/from_state/to_state
reason_code
actor_type
actor_id redacted/masked as needed
source
correlation_id
idempotency_key redacted/truncated
summary metadata redacted by FastCheck.Observability.Redactor
```

Forbidden by default:

```text
raw Paystack payload
raw Meta payload
raw WhatsApp body
buyer full phone/email in list rows
delivery token hash
QR token hash
Paystack access_code
authorization_url
plaintext ticket link
template parameter raw values when they include ticket URL/token
```

Raw-payload inspection, if ever needed, must be a later admin-only break-glass slice with explicit audit and retention rules.

---

## 9. Query and Index Rules

All dashboard reads must use indexed paths.

Required/recommended indexes:

```text
sales_orders(event_id, status, inserted_at DESC)
sales_orders(source_channel, status, inserted_at DESC)
sales_orders(status, inserted_at DESC)
sales_checkout_sessions(status, expires_at)
sales_payment_attempts(status, inserted_at DESC)
sales_payment_attempts(provider, provider_reference)
sales_payment_events(processing_status, inserted_at DESC)
sales_payment_events(provider_reference)
sales_ticket_issues(status, inserted_at DESC)
attendees(event_id, scan_eligibility)  # existing scanner/mobile truth
sales_ticket_issues(sales_order_id)
sales_delivery_attempts(status, inserted_at DESC)
sales_delivery_attempts(ticket_issue_id, inserted_at DESC)
sales_delivery_attempts(sales_order_id, inserted_at DESC)
sales_conversations(state, needs_human, last_message_at DESC)
sales_state_transitions(entity_type, entity_id, inserted_at DESC)
sales_state_transitions(correlation_id, inserted_at DESC)
attendee_invalidation_events(event_id, inserted_at DESC)
```

If the implementation uses materialized views:

```text
Use them only for aggregate dashboards.
Refresh async via Oban or scheduled job.
Never refresh materialized views synchronously inside customer checkout/payment paths.
```

---

## 10. Cache and Performance Strategy

### Hot / warm / cold layers

```text
Hot: in-memory assigns inside LiveView for current operator session; optional ETS/Cachex for 5–30s dashboard counters.
Warm: Redis/Cachex cached aggregate snapshots, TTL 10–60s, keyed by event_id/window/status.
Cold: Postgres/Ash durable Sales tables, StateTransition, AttendeeInvalidationEvent.
```

### Cache keys

If using Cachex/Redis, use stable keys like:

```text
sales:ops:summary:event:{event_id}:window:{window}
sales:ops:manual_review:event:{event_id}:window:{window}
sales:ops:delivery:event:{event_id}:window:{window}
sales:ops:payments:event:{event_id}:window:{window}
```

### Invalidation/refresh

Preferred:

```text
short TTLs over complex invalidation
telemetry-driven refresh later only if needed
manual refresh button for admin dashboard
```

Do not create cache stampedes:

```text
Use single-flight locking if cache refresh is expensive.
Use bounded query limits.
Use aggregate queries instead of loading rows.
```

---

## 11. Telemetry Integration

Extend `FastCheckWeb.Telemetry.metrics/0` using the VS-21A naming contract.

Recommended metric groups:

```text
fastcheck.sales.checkout.reserved.count
fastcheck.sales.checkout.expired.count
fastcheck.sales.checkout.release_failed.count
fastcheck.sales.payment.webhook_received.count
fastcheck.sales.payment.verified.count
fastcheck.sales.payment.mismatch.count
fastcheck.sales.payment.verification_failed.count
fastcheck.sales.ticket.issued.count
fastcheck.sales.ticket.issue_failed.count
fastcheck.sales.ticket.revoked.count
fastcheck.sales.delivery.sent.count
fastcheck.sales.delivery.failed.count
fastcheck.sales.delivery.fallback_required.count
fastcheck.sales.whatsapp.inbound_received.count
fastcheck.sales.whatsapp.outbound_sent.count
fastcheck.sales.manual_review.opened.count
fastcheck.sales.manual_review.closed.count
fastcheck.sales.inventory.reconciled.count
```

Rules:

```text
Use low-cardinality tags only.
Allowed tags: event_id only if cardinality is controlled, status, source_channel, provider, queue, reason_code.
Forbidden tags: phone, email, ticket_code, public_reference if high cardinality, provider_reference, authorization_url, token, token_hash, raw message text.
```

---

## 12. Dashboard UI Requirements

Minimum dashboard sections:

```text
Sales health cards
Payment health cards
Ticket issuing health cards
Delivery health cards
Manual review queue summary
Recent failures table
Recent StateTransition timeline
Links to order/ticket detail pages from VS-12
Links to approved manual-review action pages from VS-13
Links to approved refund/revocation UI from VS-15B
```

UI rules:

```text
Use masked buyer phone/email.
Use redacted public references where appropriate.
Show exact internal IDs only to admin/operator as already allowed by policy.
Do not show raw payloads by default.
Do not include active ticket links/tokens in tables.
Use pagination, filtering, and bounded windows.
```

---

## 13. RED/GREEN Test Plan

### RED tests first

```text
RED: ops metrics queries use bounded windows and do not load all rows.
RED: dashboard route requires dashboard_auth.
RED: customer_session/unauthenticated cannot access ops dashboard.
RED: dashboard summary masks buyer phone/email.
RED: audit timeline redacts token/hash/access_code/authorization_url/raw payload fields.
RED: telemetry metrics exist for checkout/payment/ticket/delivery/manual_review groups.
RED: high-cardinality fields are not telemetry tags.
RED: manual review queue is paginated.
RED: payment mismatch and unmatched event counters are correct.
RED: ticket issue failure and partial issuance counters are correct.
RED: delivery failure/fallback counters are correct.
RED: revocation/scanner visibility pending counters are correct.
RED: recent StateTransition timeline is ordered newest-first and paginated.
RED: no Paystack HTTP client is called.
RED: no Meta HTTP client is called.
RED: no TicketIssuer is called.
RED: no Attendee scanner mutation is called.
RED: no Redis inventory mutation is called.
```

### GREEN targets

```text
GREEN: Admin/operator has safe operational visibility.
GREEN: Query paths are indexed and bounded.
GREEN: Sensitive data is redacted consistently.
GREEN: Telemetry names are reserved and wired into FastCheckWeb.Telemetry.
GREEN: VS-22 can use these views for sandbox/E2E launch validation.
```

---

## 14. Failure Modes

| Failure | Required behavior |
|---|---|
| Metrics cache unavailable | Fall back to bounded Postgres aggregate or show stale/unavailable banner. |
| Query would exceed page/window limit | Reject or clamp to safe defaults. |
| Materialized view stale | Show freshness timestamp and allow async refresh; do not block checkout/payment. |
| Missing Sales table in partial environment | Dashboard section degrades gracefully in tests/dev only; production should fail deployment checks. |
| Redactor misses a sensitive field | Test fails; no launch approval. |
| Sentry extra data contains raw provider payload | Filter must redact before submission. |
| Manual review queue grows large | Pagination and indexes must still return quickly. |
| Telemetry tag cardinality explodes | Remove high-cardinality tag and expose value in redacted logs/audit instead. |

---

## 15. Performance and Scaling Review

```text
Layer: dashboard counters are warm/cacheable; audit detail is cold Postgres, paginated.
100k users: safe because dashboards do not sit on checkout hot path.
DB pressure: avoid large scans; aggregate by indexed status/window/event_id; cache 10–60s.
Redis representation: optional aggregate cache only; no inventory mutation.
Streaming: use pagination for audit timeline and recent failures; do not load all rows into LiveView assigns.
Materialized views: allowed for aggregates, refreshed async only.
PubSub: optional dashboard refresh broadcast from ops metrics cache refresh; no polling-heavy loops.
```

Targets:

```text
Dashboard summary load: < 500ms under normal admin use.
Manual review queue page: < 300ms on indexed path.
Audit timeline page: < 300ms for entity-scoped timeline.
No customer checkout/payment path latency regression.
No additional DB call per customer event from metrics views.
```

---

## 16. TOON Coding-Agent Prompt

| Field | Content |
|---|---|
| Task | Implement VS-21B Operational Metrics and Audit Views in `JCSchoeman96/FastCheckin`. |
| Objective | Give admins/operators safe operational visibility into Sales checkout, payment, ticketing, delivery, revocation, manual review, and audit state without adding new business mutations. |
| Output | Add `FastCheck.Sales.OpsMetrics`, `FastCheck.Sales.AuditViews`, optional `FastCheck.Sales.CachedMetrics`, LiveViews under `lib/fastcheck_web/live/sales/`, route(s) under `[:browser, :dashboard_auth]`, metric definitions in `FastCheckWeb.Telemetry`, query-path indexes, and tests for auth, redaction, pagination, metrics, and no boundary creep. |
| Note | Use existing `FastCheckWeb.Telemetry` and VS-21A telemetry names; do not create a second metrics supervisor. Use bounded windows and indexed aggregate queries; no large scans. Cache dashboard counters in Cachex/Redis for 10–60s if needed; prefer short TTLs over complex invalidation. Required indexes include `sales_orders(event_id,status,inserted_at)`, `sales_payment_attempts(status,inserted_at)`, `sales_payment_events(processing_status,inserted_at)`, `sales_ticket_issues(status,inserted_at)`, `sales_delivery_attempts(status,inserted_at)`, `sales_state_transitions(entity_type,entity_id,inserted_at)`. Redact phone/email/tokens/token_hashes/access_code/authorization_url/raw_payload/message bodies. Allowed telemetry tags are low-cardinality only: status, source_channel, provider, queue, reason_code, controlled event_id. Forbidden: phone, email, token, token_hash, ticket_code, provider_reference, authorization_url, raw body. Do not call Paystack, Meta, TicketIssuer, Attendee scanner mutation, Redis inventory, or checkout mutation code. |
| Success | Admins can see current Sales health, recent failures, manual review pressure, delivery failures, revocation visibility, and audit timelines using safe, paginated, redacted, indexed views. VS-22 can use these views for launch validation. |

---

## 17. Copy-Paste Prompt for Coding Agent

```text
You are implementing FastCheck Sales VS-21B — Operational Metrics and Audit Views in JCSchoeman96/FastCheckin.

Goal:
Add safe admin/operator operational visibility for Sales without introducing new business behavior.

Use FastCheckin truth:
- Extend existing FastCheckWeb.Telemetry instead of adding another telemetry supervisor.
- Use dashboard-auth protected LiveView routes only.
- Follow existing LoggerMetadata and SentryFilter redaction conventions.
- Build on VS-21A Redactor/TelemetryNames/Correlation modules.

Implement:
1. FastCheck.Sales.OpsMetrics for bounded aggregate summaries.
2. FastCheck.Sales.AuditViews for entity-scoped paginated audit timelines.
3. Optional FastCheck.Sales.CachedMetrics using Cachex/Redis with 10–60s TTL.
4. Sales ops LiveView under dashboard_auth.
5. Sales audit timeline LiveView under dashboard_auth.
6. Metric definitions in FastCheckWeb.Telemetry for checkout/payment/ticket/delivery/manual_review/revocation groups.
7. Query-path indexes for all dashboard filters and timelines.
8. Tests for auth, redaction, pagination, query bounds, metrics, and no forbidden side effects.

Do not:
- call Paystack or Meta clients
- verify payments
- issue tickets
- mutate Attendees/scanner/mobile sync
- mutate Redis inventory
- create checkout/order/payment state transitions
- expose raw provider payloads
- expose token hashes, QR hashes, ticket links, Paystack access codes, or authorization URLs
- use high-cardinality telemetry tags

Performance rules:
- No unbounded queries.
- No large table scans during peak.
- Cache aggregate counters where helpful.
- Paginate recent failures and audit timelines.
- Use materialized views only for aggregate dashboards and refresh them async.
```

---

## 18. Human Review Checklist

```text
[ ] Routes are dashboard-auth protected.
[ ] No public/customer dashboard access exists.
[ ] Metrics extend FastCheckWeb.Telemetry.
[ ] Telemetry tags are low-cardinality.
[ ] PII/raw payload/token fields are redacted in UI/log/Sentry paths.
[ ] Dashboard queries are bounded by window/page/event/status.
[ ] Required indexes exist or are explicitly unnecessary due to existing indexes.
[ ] Manual review queue is paginated.
[ ] Audit timeline is entity-scoped and paginated.
[ ] No Paystack client is called.
[ ] No Meta client is called.
[ ] No TicketIssuer is called.
[ ] No Attendee/scanner mutation is called.
[ ] No Redis inventory mutation is called.
[ ] Optional caches have TTLs and stale/failure behavior.
[ ] VS-22 can use this dashboard for launch validation.
```

---

## 19. Next Slice

```text
VS-22 — End-to-End Sandbox Tests
```
