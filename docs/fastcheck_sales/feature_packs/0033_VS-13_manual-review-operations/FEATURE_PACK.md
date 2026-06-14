# FastCheck Sales Feature Planning Pack — VS-13 Manual Review Operations

**Pack ID:** `0033_VS-13_manual-review-operations`  
**Slice:** `VS-13`  
**Slice name:** Manual Review Operations  
**Version:** `v1.0`  
**Date:** 2026-06-13  
**Status:** Implementation planning pack  
**Primary area:** Admin Operations / Manual Review / Audit / Recovery  
**Repo truth:** `JCSchoeman96/FastCheckin`  
**Repository path:** `docs/fastcheck_sales/feature_packs/0033_VS-13_manual-review-operations`  
**Source docs:**  
- `docs/fastcheck_sales/SOURCE_DOCS/FastCheck_Sales_Ash_Atlas_Planning_Pack_v0.2.3_HARDENED.md`  
- `docs/fastcheck_sales/SOURCE_DOCS/FastCheck_Sales_Vertical_Slice_Roadmap_v1.1.3_HARDENED.md`  
**Depends on:** VS-07C, VS-09D, VS-10, VS-11, VS-12, VS-01F, VS-01G, VS-00A, VS-00B, VS-21A  
**Blocks:** VS-15A, VS-15B, VS-19, VS-21B, VS-22, VS-23B

---

## 1. Purpose

VS-13 adds the first controlled operator workflow for orders, payments, and issuance records that were deliberately placed into `manual_review` by earlier slices.

The goal is not to give admins a “fix anything” console.

The goal is:

```text
manual_review state
  -> visible to authenticated dashboard operator
  -> reviewed with bounded reason codes and notes
  -> either queued for a safe retry, held for later investigation, or resolved without fulfillment
  -> every decision audited through StateTransition / review action logs
```

Manual review must be a safety layer around already-defined state machines, not a bypass around Paystack verification, Redis inventory rules, Attendee creation, scanner rules, or ticket delivery.

---

## 2. FastCheckin Repo Findings Used

The current FastCheckin backend already provides relevant operational patterns:

```text
FastCheckWeb.Router
  browser dashboard routes under [:browser, :dashboard_auth]

FastCheckWeb.DashboardLive
  existing LiveView admin dashboard pattern
  sync operation buttons and status feedback

FastCheckWeb.Plugs.BrowserAuth
  lightweight dashboard authentication
  assigns current_user = %{id: username, username: username}
  exposes valid_admin_password?/1 for sensitive in-session actions

FastCheck.Attendees.Attendee
  existing scanner/runtime ticket truth

FastCheck.Attendees.Reconciliation
  current not_scannable/invalidation model
```

Implication:

```text
VS-13 should add Sales manual-review operations beside the admin dashboard pattern,
not inside scanner/check-in modules,
not inside webhook controllers,
and not as generic Ash status updates.
```

---

## 3. Ultimate Outcome

After VS-13:

```text
An authenticated dashboard operator can inspect Sales orders/payment attempts/ticket issues in manual_review.
The operator can add a review note.
The operator can assign/unassign a review item.
The operator can queue a safe payment verification retry.
The operator can queue a safe issuance retry.
The operator can mark a review as "no fulfillment / closed" only with reason and audit trail.
The operator cannot mark an order paid manually.
The operator cannot issue tickets directly from the LiveView.
The operator cannot refund/revoke/resend tickets in this slice.
The operator cannot see raw provider payloads or plaintext customer tokens.
Every action appends a StateTransition or ManualReviewAction audit record.
```

---

## 4. Scope

### In scope

```text
Add ManualReviewAction durable audit resource/table if not already present.
Add Sales manual-review query/service boundary.
Add authenticated LiveView or dashboard tab for manual-review queue.
Add read-only detail panel for order/payment/issuance context.
Add bounded operator actions:
  - assign_to_self
  - unassign
  - add_note
  - retry_payment_verification
  - retry_ticket_issuance
  - hold_for_investigation
  - close_no_fulfillment
  - return_to_fulfillment_queue only when all safe preconditions pass
Append StateTransition for state changes.
Enqueue Oban retry jobs rather than doing heavy work in LiveView.
Mask PII by default.
Require reason codes for all state-changing review actions.
Use `conn.assigns.current_user` / LiveView session actor derived from BrowserAuth username as the actor marker until richer RBAC exists.
```

### Out of scope

```text
No manual mark-paid action.
No direct ticket issuance from LiveView.
No direct Attendee creation from LiveView.
No provider refund API call.
No local refund state implementation.
No revocation scanner behavior.
No ticket resend / WhatsApp / email delivery.
No DeliveryAttempt creation.
No Paystack HTTP call inside LiveView process.
No raw webhook/provider payload viewer.
No full RBAC redesign.
No customer support portal.
```

---

## 5. Domain Model

### New resource/table: `ManualReviewAction`

Recommended module:

```text
lib/fastcheck/sales/manual_review_action.ex
```

Recommended table:

```text
sales_manual_review_actions
```

Fields:

```text
id uuid_v7 or repo-standard primary key
subject_type enum[order, payment_attempt, payment_event, ticket_issue, checkout_session]
subject_id uuid/integer string-compatible
sales_order_id nullable indexed
payment_attempt_id nullable indexed
payment_event_id nullable indexed
ticket_issue_id nullable indexed
checkout_session_id nullable indexed
action enum
reason_code enum
note text nullable sanitized
actor_type enum[dashboard_user, system]
actor_id string nullable
actor_label string nullable
previous_status string nullable
new_status string nullable
metadata map default %{}
correlation_id string nullable
inserted_at utc_datetime_usec
```

Do not store:

```text
raw Paystack payloads
Authorization headers
Paystack secrets
access_code
authorization_url
plaintext ticket_code if not required for support view
plaintext qr_token
plaintext delivery_token
full buyer phone/email in metadata
```

### Existing / prior resources touched

```text
FastCheck.Sales.Order
FastCheck.Sales.PaymentAttempt
FastCheck.Sales.PaymentEvent
FastCheck.Sales.TicketIssue
FastCheck.Sales.StateTransition
FastCheck.Attendees.Attendee read-only for support context
FastCheck.Events.Event read-only for event labels
```

### Service boundary

Recommended module:

```text
lib/fastcheck/sales/manual_review.ex
```

Public functions:

```text
list_queue(filters, opts)
get_context(subject_type, subject_id, opts)
assign(subject_type, subject_id, actor, attrs)
unassign(subject_type, subject_id, actor, attrs)
add_note(subject_type, subject_id, actor, attrs)
hold_for_investigation(subject_type, subject_id, actor, attrs)
close_no_fulfillment(subject_type, subject_id, actor, attrs)
retry_payment_verification(payment_attempt_id, actor, attrs)
retry_ticket_issuance(order_id, actor, attrs)
return_to_fulfillment_queue(order_id, actor, attrs)
```

Rules:

```text
Service may call Ash actions or plain modules that wrap Ash.
Service may enqueue Oban jobs.
Service must never directly call Paystack HTTP.
Service must never directly call Attendees creation.
Service must never write scanner fields.
Service must never mutate Redis inventory.
```

---

## 6. State Machine Rules

Manual review should only move between named states.

Allowed state transitions:

```text
manual_review -> verification_retry_queued
manual_review -> issuance_retry_queued
manual_review -> manual_review_held
manual_review -> no_fulfillment_closed
manual_review -> fulfillment_queued only if all preconditions pass
verification_retry_queued -> manual_review when retry fails safe
issuance_retry_queued -> manual_review when retry fails safe
manual_review_held -> manual_review
```

Forbidden transitions:

```text
manual_review -> paid_verified by operator click
manual_review -> ticket_issued by operator click
manual_review -> refunded by operator click
manual_review -> revoked by operator click
manual_review -> delivered by operator click
```

`return_to_fulfillment_queue` preconditions:

```text
Order is already provider-verified through VS-07B/VS-07C.
No unresolved amount/currency/reference mismatch exists.
No expired checkout unrecovered inventory issue remains.
No duplicate-payment ambiguity remains.
Required Attendee/TicketIssue preconditions from VS-09D pass.
Operator supplies reason code and note.
```

If any precondition is false:

```text
return {:error, :unsafe_manual_review_transition}
append no state transition
append ManualReviewAction attempt only if useful and non-sensitive
```

---

## 7. UI / Route Plan

Preferred route:

```text
live "/dashboard/sales/reviews", SalesManualReviewLive, :index
```

Must be placed under existing dashboard-authenticated browser scope:

```text
scope "/", FastCheckWeb do
  pipe_through [:browser, :dashboard_auth]
end
```

Preferred LiveView:

```text
lib/fastcheck_web/live/sales_manual_review_live.ex
```

UI areas:

```text
Summary cards:
  manual_review_count
  verification_retry_needed_count
  issuance_retry_needed_count
  held_count

Queue table:
  inserted_at
  subject_type
  order reference
  event name
  reason_code
  safe masked buyer summary
  current status
  assigned_to
  last_action_at

Detail panel:
  timeline of StateTransition + ManualReviewAction
  payment summary with masked fields
  ticket/attendee summary with IDs and scanner status only
  recommended next safe action

Actions:
  assign/unassign
  add_note
  queue payment verification retry
  queue issuance retry
  hold
  close no fulfillment
  return to fulfillment queue when safe
```

PII display:

```text
Email: jo***@example.com or hidden unless admin reveals in a future sensitive action.
Phone: +27******1234.
Provider reference: show last 6 only by default.
Ticket code: show last 4 only by default unless needed for support diagnostics.
Never show raw tokens or raw payloads.
```

---

## 8. Oban Retry Boundaries

Manual review actions that trigger work must enqueue jobs.

Allowed jobs:

```text
FastCheck.Workers.VerifyPaymentWorker
FastCheck.Workers.IssueTicketsWorker
```

or repo-equivalent names from prior slices.

Rules:

```text
LiveView must not perform external HTTP.
LiveView must not run issuer logic inline.
LiveView must not hold long DB transactions.
Retry jobs must be unique by subject/idempotency key.
Retry jobs must re-check all preconditions when they run.
Manual review action only queues the retry; the worker decides success/failure.
```

---

## 9. Indexes and Query Performance

Required indexes:

```text
sales_manual_review_actions subject_type, subject_id, inserted_at desc
sales_manual_review_actions sales_order_id, inserted_at desc
sales_manual_review_actions actor_id, inserted_at desc
sales_orders status, inserted_at desc
sales_orders manual_review_reason_code, inserted_at desc if field exists
sales_payment_attempts status, inserted_at desc
sales_ticket_issues status, inserted_at desc
sales_state_transitions subject_type, subject_id, inserted_at desc
```

Manual-review queue query rules:

```text
Always paginate.
Default limit <= 50.
Filters must be indexed.
No full table scans over all orders/payments/tickets.
No preloading raw payload blobs.
No loading all StateTransitions for all queue rows.
Use per-subject detail query when an operator opens an item.
```

---

## 10. Performance and Scaling Review

### Data layer

```text
Manual review queue: cold/durable Postgres.
Dashboard summary counts: warm Cachex/Redis optional TTL 10s-60s.
Open review item detail: Postgres indexed read.
LiveView state: hot process memory only for current operator session.
Job retries: Oban/Postgres durable queue.
No Redis inventory mutation in VS-13.
```

### Cache rules

```text
Summary counts may be cached with 10s-60s TTL.
Invalidate dashboard count cache after ManualReviewAction insert or subject state transition.
Do not cache raw provider payloads.
Do not cache unmasked PII.
```

### PubSub rules

```text
Broadcast manual-review count/queue update after successful action.
Topic: sales:manual_review or existing PubSub naming style.
Do not broadcast PII.
Payload should contain counts and subject IDs only.
```

### 100k-user safety

```text
VS-13 is operator-side, not public checkout-side.
Still avoid accidental scans over payment/order/ticket tables.
All retry actions must enqueue jobs and return fast.
No external HTTP in LiveView.
No unbounded LiveView assigns.
```

---

## 11. Security Rules

```text
Manual review routes must remain under dashboard_auth.
Every state-changing action must have actor, reason_code, timestamp, before/after status.
Use BrowserAuth current_user username as actor_id until richer RBAC exists.
Sensitive actions should require a confirmation modal and may use valid_admin_password?/1 if consistent with existing dashboard sensitive-action pattern.
Do not log PII, raw payloads, ticket codes, QR/delivery tokens, Paystack access_code, or authorization_url.
Sanitize operator notes for HTML/script content.
Do not expose raw payloads in assigns.
Do not expose complete provider payloads in browser HTML.
```

---

## 12. Failure Modes

| Failure | Required behavior |
|---|---|
| Operator double-clicks retry | Idempotent retry job enqueue; one effective job. |
| Two operators act on same item | Optimistic lock/state guard; second action receives stale-state error. |
| Retry job already running | Show queued/running state; do not enqueue duplicate. |
| Payment mismatch unresolved | Block fulfillment queue transition. |
| Issuance preconditions fail | Keep manual_review and show safe reason. |
| Operator closes item accidentally | Require confirmation and reason; audit action. |
| Dashboard auth missing | Redirect/deny using existing BrowserAuth. |
| Payload contains PII | Mask in UI; redact logs. |
| Cache unavailable | Fall back to indexed Postgres reads. |

---

## 13. RED/GREEN Test Plan

### RED tests

```text
RED: unauthenticated user cannot access /dashboard/sales/reviews.
RED: manual-review queue lists only manual_review/held/retry-needed subjects.
RED: queue is paginated and bounded.
RED: order detail hides raw provider payloads and plaintext tokens.
RED: add_note creates ManualReviewAction with actor/reason/note.
RED: assign_to_self sets assignment and creates audit action.
RED: retry_payment_verification enqueues VerifyPaymentWorker and does not call Paystack inline.
RED: retry_ticket_issuance enqueues IssueTicketsWorker and does not create attendees/ticket issues inline.
RED: return_to_fulfillment_queue is blocked if amount/currency/reference mismatch exists.
RED: return_to_fulfillment_queue is blocked if payment is not provider-verified.
RED: close_no_fulfillment requires reason and confirmation.
RED: manual mark-paid action does not exist.
RED: refund/revoke/resend actions do not exist.
RED: operator notes are sanitized.
RED: PubSub broadcast excludes PII.
RED: log capture does not contain raw provider payload, email, phone, ticket code, or token values.
```

### GREEN targets

```text
GREEN: authenticated dashboard operator can view manual-review queue.
GREEN: operator can add audited note.
GREEN: operator can assign/unassign with audit.
GREEN: operator can queue safe retry jobs only.
GREEN: unsafe state transitions fail closed.
GREEN: all actions append ManualReviewAction and StateTransition where applicable.
GREEN: dashboard remains responsive under pagination.
GREEN: existing dashboard, scanner, mobile sync, and reconciliation tests remain green.
```

---

## 14. TOON Coding-Agent Prompt

| Field | Content |
|---|---|
| Task | Implement VS-13 Manual Review Operations in `JCSchoeman96/FastCheckin`. |
| Objective | Give authenticated FastCheck dashboard operators a safe, audited way to inspect and handle Sales orders/payments/tickets in `manual_review` without bypassing Paystack verification, issuance idempotency, scanner rules, or future refund/revoke/delivery workflows. |
| Output | Add `lib/fastcheck/sales/manual_review.ex`; add `lib/fastcheck/sales/manual_review_action.ex` or Ash resource equivalent; add migration for `sales_manual_review_actions`; add `lib/fastcheck_web/live/sales_manual_review_live.ex`; add dashboard-auth route `/dashboard/sales/reviews`; add tests under `test/fastcheck/sales/` and `test/fastcheck_web/live/`; update docs/changelog if repo convention requires. |
| Note | Use FastCheckin repo truth. Place LiveView route under existing `[:browser, :dashboard_auth]`. Use `FastCheckWeb.Plugs.BrowserAuth` current_user username as actor marker. Do not build broad RBAC. State-changing actions require reason_code and audit. Allowed actions: assign, unassign, add_note, hold, close_no_fulfillment, queue payment verification retry, queue issuance retry, return_to_fulfillment_queue only when all preconditions are true. Forbidden: manual mark-paid, direct ticket issue, direct attendee mutation, direct Paystack HTTP, refund/revoke/resend, DeliveryAttempt, WhatsApp/email, Redis inventory mutation, raw provider payload viewing. Required indexes: review subject, order, actor, status/date query indexes. Cache dashboard counts for 10s-60s only; invalidate after review actions. PubSub update payloads must not include PII. Use Oban jobs for retries; keep LiveView actions fast. No full table scans; paginate <= 50 by default. |
| Success | Operators can safely handle manual-review work with full auditability, retry jobs are queued idempotently, unsafe transitions fail closed, no sensitive payloads leak, and existing scanner/mobile/dashboard behavior remains unchanged. |

---

## 15. Copy-Paste Prompt for Coding Agent

```text
You are implementing FastCheck Sales VS-13 — Manual Review Operations in the FastCheckin repo.

Repo truth:
- module root: FastCheck
- dashboard route pattern: FastCheckWeb.Router under [:browser, :dashboard_auth]
- admin dashboard pattern: FastCheckWeb.DashboardLive
- auth actor source: FastCheckWeb.Plugs.BrowserAuth assigns current_user username
- scanner truth: FastCheck.Attendees.Attendee / FastCheck.Attendees.Scan

Implement a safe manual-review operations boundary.

Add:
1. ManualReviewAction durable audit table/resource.
2. FastCheck.Sales.ManualReview service module.
3. FastCheckWeb.SalesManualReviewLive under /dashboard/sales/reviews.
4. Tests for queue, detail, action audit, retry job enqueue, unsafe transition blocking, masking, and boundary creep.

Allowed operator actions:
- assign_to_self
- unassign
- add_note
- hold_for_investigation
- close_no_fulfillment
- retry_payment_verification by enqueuing worker only
- retry_ticket_issuance by enqueuing worker only
- return_to_fulfillment_queue only when provider-verified and mismatch-free

Forbidden:
- manual mark-paid
- direct ticket issuance from LiveView
- direct Attendee creation from LiveView
- Paystack HTTP inside LiveView
- refund/revoke/resend
- DeliveryAttempt creation
- WhatsApp/email behavior
- Redis inventory mutation
- raw provider payload viewer
- plaintext QR/delivery-token display

All state-changing actions must:
- require reason_code
- attach actor_id from current dashboard user
- append ManualReviewAction
- append StateTransition where subject state changes
- sanitize notes
- mask PII
- avoid logging sensitive fields

Performance:
- paginate queue <= 50
- use indexed filters
- cache summary counts at 10s-60s TTL only
- invalidate count cache after actions
- use PubSub for count refresh with no PII

Run the relevant tests plus existing dashboard/scanner/mobile/reconciliation tests.
```

---

## 16. Human Review Checklist

```text
[ ] Route is under dashboard_auth.
[ ] No public manual-review endpoints exist.
[ ] ManualReviewAction audit exists.
[ ] Every action has actor/reason/timestamp.
[ ] No manual mark-paid button exists.
[ ] No direct issue-ticket button exists.
[ ] No refund/revoke/resend button exists.
[ ] Retry actions enqueue jobs only.
[ ] Unsafe transitions fail closed.
[ ] Raw provider payloads are not rendered.
[ ] PII is masked in queue/detail.
[ ] Notes are sanitized.
[ ] Queue is paginated and indexed.
[ ] Summary cache TTL/invalidation documented.
[ ] PubSub payloads contain no PII.
[ ] Existing scanner/mobile sync/reconciliation tests remain green.
```

---

## 17. Next Slice

```text
VS-14 — Checkout Expiry and Cleanup
```
