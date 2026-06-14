# FastCheck Sales Feature Planning Pack — VS-12 Admin Sales Dashboard

**Pack ID:** `0032_VS-12_admin-sales-dashboard`  
**Slice:** `VS-12`  
**Slice name:** Admin Sales Dashboard  
**Version:** `v1.0`  
**Date:** 2026-06-13  
**Status:** Implementation planning pack  
**Primary area:** Admin / Sales Visibility / LiveView / Read Models / Manual Review Queue  
**Repo truth:** `JCSchoeman96/FastCheckin`  
**Repository path:** `docs/fastcheck_sales/feature_packs/0032_VS-12_admin-sales-dashboard`  
**Source docs:**  
- `docs/fastcheck_sales/SOURCE_DOCS/FastCheck_Sales_Ash_Atlas_Planning_Pack_v0.2.3_HARDENED.md`  
- `docs/fastcheck_sales/SOURCE_DOCS/FastCheck_Sales_Vertical_Slice_Roadmap_v1.1.3_HARDENED.md`  
**Depends on:** VS-01F, VS-01G, VS-03, VS-04C, VS-05, VS-05A, VS-06B, VS-07A, VS-07B, VS-07C, VS-09C, VS-09D, VS-10, VS-21A  
**Blocks:** VS-13, VS-14, VS-15B, VS-19, VS-21B, VS-22, VS-23B

---

## 1. Purpose

VS-12 adds an operator-facing **Admin Sales Dashboard** to FastCheckin.

The dashboard must give staff safe visibility into Sales orders, payments, ticket issuance, manual-review cases, inventory state summaries, and delivery readiness without introducing destructive operations too early.

This is primarily a **read + triage** slice.

It must not become the refund/revoke/manual-override engine. Those workflows are later slices.

---

## 2. FastCheckin Repo Truth

The correct repository is:

```text
JCSchoeman96/FastCheckin
```

Current repo shape to respect:

```text
Phoenix app: FastCheck
Module root: FastCheck
Web root: FastCheckWeb
Existing admin LiveView: FastCheckWeb.DashboardLive
Existing occupancy LiveView: FastCheckWeb.OccupancyLive
Existing browser dashboard auth: FastCheckWeb.Plugs.BrowserAuth
Existing router dashboard scope: `/`, `/dashboard`, `/scan/:event_id`, `/dashboard/occupancy/:event_id`
Existing attendees: FastCheck.Attendees.Attendee
Existing scanner path: FastCheck.Attendees.Scan
Existing mobile sync path: FastCheckWeb.Mobile.SyncController
```

Observed repo constraints:

```text
Dashboard routes already use `pipe_through [:browser, :dashboard_auth]`.
BrowserAuth assigns `:current_user` with a dashboard username.
DashboardLive already manages events, Tickera sync, and admin event actions.
OccupancyLive already uses PubSub for real-time operational metrics.
SecurityHeaders already applies browser CSP/security headers.
```

Do not create a second unrelated admin shell. Extend the existing admin/dashboard pattern cleanly.

---

## 3. Ultimate Goal

Long-term Admin Sales should let staff see and operate the full Sales lifecycle:

```text
sales channels
orders
checkout sessions
payment attempts/events
verification status
manual review cases
inventory reservations/recovery
attendee issuance
TicketIssue audit links
secure ticket pages
delivery attempts
refund/revocation workflows
support diagnostics
sales analytics
```

VS-12 is the smallest useful slice of that goal:

```text
Authenticated admin can open `/dashboard/sales`.
Admin can see high-level Sales KPIs.
Admin can list recent orders and filter by status/channel/event.
Admin can inspect a single order summary.
Admin can see payment verification and mismatch state.
Admin can see ticket issuance state and linked Attendee/TicketIssue counts.
Admin can see manual-review queue entries.
Admin cannot perform destructive mutations yet.
```

---

## 4. MVP Scope

### In scope

```text
Add a new LiveView route under the existing authenticated dashboard scope.
Create `FastCheckWeb.SalesDashboardLive` or `FastCheckWeb.Admin.SalesDashboardLive` following existing LiveView conventions.
Create read-model/query module for dashboard summaries.
Expose lightweight dashboard cards: orders today, paid verified, issued, failed/mismatch, manual review, expired checkout.
Add recent order table with filters.
Add manual-review queue table.
Add order detail drawer/panel or detail route if simpler.
Show safe summaries of PaymentAttempt, PaymentEvent, CheckoutSession, TicketIssue, and Attendee linkage.
Show inventory reservation summary via approved Sales/Inventory service only, not direct Redis key access.
Add pagination/limits to all lists.
Add tests for auth, visibility, filtering, no raw payload leakage, and no destructive actions.
```

### Out of scope

```text
No refund action.
No revoke action.
No manual override mutation.
No resend-ticket action.
No WhatsApp/email delivery action.
No Paystack API calls from LiveView.
No Redis inventory mutation from LiveView.
No scanner/mobile sync mutation.
No event creation/sync behavior changes.
No broad analytics dashboard with unbounded scans.
No organiser dashboard or multi-tenant organiser permissions.
```

---

## 5. Recommended Files

Use existing FastCheckin naming style.

```text
lib/fastcheck/sales/admin_dashboard.ex
lib/fastcheck/sales/admin_dashboard/order_summary.ex       # optional struct only if useful
lib/fastcheck_web/live/sales_dashboard_live.ex
lib/fastcheck_web/live/sales_dashboard_live.html.heex      # only if project pattern uses external templates
lib/fastcheck_web/router.ex

test/fastcheck/sales/admin_dashboard_test.exs
test/fastcheck_web/live/sales_dashboard_live_test.exs
```

Avoid adding a new top-level `admin` context unless the repo already has one by the time this slice runs.

---

## 6. Route Design

Add route inside the existing authenticated dashboard browser scope:

```elixir
scope "/", FastCheckWeb do
  pipe_through [:browser, :dashboard_auth]

  live "/dashboard/sales", SalesDashboardLive, :index
end
```

Rules:

```text
Must reuse `:dashboard_auth`.
Must not expose Sales dashboard under public browser or API scopes.
Must not add a separate auth plug in this slice.
Must not require AshAuthentication unless the project later replaces BrowserAuth globally.
```

---

## 7. Dashboard Data Model

Dashboard query module should return safe read models, not raw Ash resources/provider payloads.

Recommended public functions:

```text
FastCheck.Sales.AdminDashboard.summary(filters \\ %{})
FastCheck.Sales.AdminDashboard.recent_orders(filters \\ %{}, opts \\ [])
FastCheck.Sales.AdminDashboard.manual_review_queue(filters \\ %{}, opts \\ [])
FastCheck.Sales.AdminDashboard.order_detail(order_id)
```

Read models should include only safe fields:

```text
order_public_reference
order_status
source_channel
event_id
buyer_name_display or masked buyer summary
buyer_email_masked
buyer_phone_masked
amount_cents
currency
payment_status_summary
verification_status
checkout_status
issued_ticket_count
expected_ticket_count
manual_review_reason
inserted_at
updated_at
```

Do not expose:

```text
raw Paystack payloads
full webhook payloads
authorization_url
access_code
provider authorization objects
full delivery_token
full qr_token
unhashed tokens
secret config
buyer PII beyond masked summaries
```

---

## 8. Filters and Pagination

Minimum filters:

```text
status
source_channel
event_id
payment_status
manual_review_only
from_date
to_date
search by order_public_reference only
```

Pagination rules:

```text
Default limit: 25
Max limit: 100
Stable order: inserted_at desc, id desc
No unbounded Repo.all over orders/payments/tickets
No full-text search across buyer PII in MVP
```

---

## 9. Manual Review Queue

Manual review list must be read-only in VS-12.

Show:

```text
order_public_reference
reason_code
reason_summary
source_channel
payment_attempt status
payment_event status
checkout state
created_at
last_transition_at
next recommended operator action text
```

Allowed operator action in VS-12:

```text
open detail
copy order reference
view safe audit trail summary
```

Forbidden operator action in VS-12:

```text
resolve review
mark paid
issue ticket
release inventory
refund payment
revoke ticket
resend ticket
change attendee data
```

---

## 10. LiveView Real-Time Behavior

Do not poll.

Preferred:

```text
subscribe to a Sales admin PubSub topic only if VS-21A/VX state broadcasts already exist.
otherwise use initial load + user-triggered filter refresh.
```

If adding PubSub:

```text
Topic: sales:admin_dashboard
Broadcast only summary invalidation events, not raw order/payment payloads.
LiveView reloads query module after receiving event.
```

Do not broadcast raw PII or provider payloads.

---

## 11. Caching and Performance

### Data layer

```text
Hot: LiveView assigns only for the current dashboard page; optional ETS/Cachex summary cache with 5s-30s TTL.
Warm: Redis/Cachex aggregate cache may be introduced only via a dedicated Sales dashboard cache module.
Cold: Postgres/Ash durable Sales data is source of truth.
```

### Required query constraints

```text
No dashboard query may scan full orders table during peak.
Use status/channel/event/date indexes from previous slices.
Use aggregate counts constrained by time/status or cached materialized summaries.
Use read-only query functions.
Use explicit select maps instead of loading large nested resources.
Do not load raw PaymentEvent payloads.
```

### Recommended cache keys

```text
sales:admin_dashboard:summary:{filter_hash}
sales:admin_dashboard:manual_review_count:{event_id|all}
```

TTL:

```text
summary cache: 5s-30s
manual review count cache: 5s-30s
recent orders: generally uncached or <= 5s TTL
```

Invalidation triggers:

```text
Order state transition
PaymentAttempt verification transition
PaymentEvent processed/unmatched/manual_review transition
TicketIssue created/revoked
CheckoutSession expired
Manual review reason created/updated
```

---

## 12. Security Rules

```text
Use existing dashboard_auth route protection.
Never display full buyer phone/email by default.
Never display raw provider payloads.
Never display unhashed token values.
Never log dashboard filter values if they may include PII.
Never allow arbitrary query params to become dynamic SQL fragments.
Escape/sanitize user-visible strings through normal Phoenix rendering.
Do not add export/download of Sales data in this slice.
```

---

## 13. RED/GREEN Test Plan

### RED tests first

```text
RED: unauthenticated user cannot access `/dashboard/sales`.
RED: authenticated dashboard user can access `/dashboard/sales`.
RED: summary cards render safe counts from Sales read model.
RED: recent orders table respects limit and stable order.
RED: filters do not trigger unbounded query behavior.
RED: manual-review queue shows reason code and order reference.
RED: dashboard does not render raw PaymentEvent payload.
RED: dashboard does not render full delivery token, QR token, access_code, or authorization_url.
RED: dashboard does not expose full buyer phone/email by default.
RED: dashboard has no refund/revoke/resend/mark-paid/issue-ticket controls.
RED: order detail view shows Attendee/TicketIssue linkage counts but not raw scanner mutation controls.
RED: existing DashboardLive, OccupancyLive, scanner, and mobile sync tests remain green.
```

### GREEN implementation targets

```text
GREEN: route added under authenticated browser dashboard scope.
GREEN: LiveView renders summary, recent orders, manual review queue, and safe order details.
GREEN: all lists are paginated and bounded.
GREEN: query module returns safe maps/structs only.
GREEN: no destructive admin mutations exist in VS-12.
GREEN: log redaction tests pass.
GREEN: security boundary tests pass.
```

---

## 14. TOON Coding-Agent Prompt

| Field | Content |
|---|---|
| Task | Implement the VS-12 Admin Sales Dashboard in FastCheckin. |
| Objective | Give authenticated staff safe read-only visibility into Sales orders, payment verification, ticket issuance, and manual-review queues without enabling destructive operations before the refund/revoke/manual-review operation slices. |
| Output | Add `lib/fastcheck/sales/admin_dashboard.ex`; add `lib/fastcheck_web/live/sales_dashboard_live.ex`; update `lib/fastcheck_web/router.ex`; add tests in `test/fastcheck/sales/admin_dashboard_test.exs` and `test/fastcheck_web/live/sales_dashboard_live_test.exs`; final report listing indexes used, fields redacted, and deferred mutation actions. |
| Note | Use `JCSchoeman96/FastCheckin` conventions: module root `FastCheck`, web root `FastCheckWeb`, existing `DashboardLive`, `OccupancyLive`, `BrowserAuth`, and router dashboard scope. Add route under `pipe_through [:browser, :dashboard_auth]`. Keep this read-only: no refund, revoke, resend, mark-paid, issue-ticket, Paystack call, WhatsApp/email delivery, Redis inventory mutation, scanner mutation, or mobile sync mutation. Use safe read models; do not expose raw provider payloads, access_code, authorization_url, full buyer email/phone, QR token, delivery token, or unhashed tokens. Performance: bounded queries, default limit 25/max 100, stable order by inserted_at desc/id desc, use indexes from previous slices, optional 5s-30s Cachex summary cache. PubSub optional only for invalidation signals, never raw payloads. Tests must prove auth, safe rendering, bounded lists, no destructive controls, no secret/PII leakage, and existing dashboard/scanner/mobile tests remain green. |
| Success | Staff can safely inspect Sales health and manual-review items from `/dashboard/sales`; all data is bounded/redacted; no operator can mutate payments, tickets, inventory, delivery, scanner state, or attendee data from this slice. |

---

## 15. Copy-Paste Prompt for Coding Agent

```text
You are implementing FastCheck Sales VS-12 — Admin Sales Dashboard in the FastCheckin repo.

Use repo truth:
- App/module root: FastCheck
- Web root: FastCheckWeb
- Existing admin LiveView: FastCheckWeb.DashboardLive
- Existing browser auth plug: FastCheckWeb.Plugs.BrowserAuth
- Existing router dashboard scope uses `pipe_through [:browser, :dashboard_auth]`

Implement a read-only Sales admin dashboard:
1. Add route `live "/dashboard/sales", SalesDashboardLive, :index` under the existing authenticated dashboard browser scope.
2. Add `FastCheck.Sales.AdminDashboard` as the query/read-model boundary.
3. Add `FastCheckWeb.SalesDashboardLive` following current LiveView style.
4. Show summary cards, recent orders, manual review queue, and safe order detail summary.
5. Use bounded queries and safe select maps; do not load raw provider payloads.
6. Add tests for auth, rendering, filters, redaction, bounded queries, and absence of destructive controls.

Do not implement:
- refund
- revoke
- resend
- mark paid
- issue ticket
- Paystack API calls
- WhatsApp/email delivery
- DeliveryAttempt changes
- Redis inventory mutation
- scanner/mobile sync mutation
- raw payload display or export

Security:
- Mask buyer email/phone by default.
- Never display access_code, authorization_url, raw provider payloads, QR token, delivery token, or unhashed tokens.
- Do not log PII-like filter/search values.

Performance:
- Default list limit 25; max 100.
- Stable order: inserted_at desc, id desc.
- Use indexes from previous slices.
- Optional Cachex summary cache TTL 5s-30s; invalidate on Sales state transitions.
```

---

## 16. Human Review Checklist

```text
[ ] Route is under existing dashboard_auth browser scope.
[ ] Dashboard cannot be accessed unauthenticated.
[ ] Dashboard query module uses bounded/paginated reads.
[ ] No raw provider payloads shown.
[ ] No full buyer phone/email shown by default.
[ ] No plaintext QR/delivery token shown except safe QR payload when explicitly required by ticket page, not dashboard.
[ ] No refund/revoke/resend/mark-paid/issue-ticket controls exist.
[ ] Manual-review queue is read-only.
[ ] Existing DashboardLive still works.
[ ] Existing OccupancyLive still works.
[ ] Existing scanner/mobile sync tests remain green.
[ ] Performance review completed for every query.
[ ] Final report lists indexes/caches used and deferred VS-13/VS-15B operations.
```

---

## 17. Next Slice

```text
VS-13 — Manual Review Operations
```
