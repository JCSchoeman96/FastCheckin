# FastCheck Sales Feature Planning Pack — VS-15B Admin Refund and Revocation Operations

**Pack ID:** `0036_VS-15B_admin-refund-and-revocation-operations`  
**Slice:** `VS-15B`  
**Slice name:** Admin Refund and Revocation Operations  
**Version:** `v1.0`  
**Date:** 2026-06-13  
**Status:** Implementation-ready admin/ops slice, dependent on VS-13 and VS-15A  
**Primary area:** LiveView Admin / Sales Ops / Refund & Revocation / Audit  
**Repo truth:** `JCSchoeman96/FastCheckin`  
**Repository path:** `docs/fastcheck_sales/feature_packs/0036_VS-15B_admin-refund-and-revocation-operations/`  
**Source docs:** `docs/fastcheck_sales/SOURCE_DOCS/FastCheck_Sales_Ash_Atlas_Planning_Pack_v0.2.3_HARDENED.md`, `docs/fastcheck_sales/SOURCE_DOCS/FastCheck_Sales_Vertical_Slice_Roadmap_v1.1.3_HARDENED.md`  
**Normalization:** Batch `0035_0037`, normalized 2026-06-14  
**Depends on:** VS-13, VS-15A, VS-12, VS-10, VS-09D, VS-07C, VS-00A, VS-00B, VS-01F, VS-21A  
**Blocks:** VS-20, VS-21B, VS-22, VS-23B, paid-event launch if admin refund/revoke is launch-supported  

---

## 1. Purpose

Add audited admin/operator operations for refund and revocation workflows.

This slice builds the **admin-facing control layer** over the VS-15A core revocation path. It must not implement a second scanner-revocation mechanism.

Correct flow:

```text
Admin/operator review action
  -> permission + reason challenge
  -> Sales manual-review / refund / revocation transition
  -> FastCheck.Tickets.Revocation core path from VS-15A
  -> existing Attendee scan_eligibility not_scannable
  -> AttendeeInvalidationEvent append
  -> event sync aggregation
  -> StateTransition audit
  -> dashboard refresh
```

Key rule:

```text
VS-15B is an admin/ops orchestration slice.
VS-15A remains the scanner-safety authority.
```

---

## 2. FastCheckin Current-State Findings

Use these current FastCheckin truths:

```text
Dashboard routes already run through [:browser, :dashboard_auth].
FastCheckWeb.DashboardLive is the existing admin dashboard pattern.
FastCheckWeb.Plugs.BrowserAuth assigns current_user for dashboard sessions.
BrowserAuth.valid_admin_password?/1 exists for sensitive in-session checks.
FastCheck.Attendees.Attendee.scan_eligibility = "not_scannable" is scanner-denied.
FastCheck.Attendees.AttendeeInvalidationEvent is the mobile tombstone/invalidation path.
FastCheck.Scans.HotState.DbAuthority protects mobile hot-state scans from stale Redis snapshots.
```

Therefore this slice should add a Sales admin LiveView/action surface that calls approved Sales and Tickets services.

Do not bypass the existing dashboard auth pipeline.

---

## 3. Ultimate Outcome

After VS-15B:

```text
Admin users can revoke/refund Sales-issued tickets through audited actions.
Operators can only perform the limited actions allowed by VS-01F/VS-13 policy.
Every admin/manual action requires a reason.
Sensitive actions may require password confirmation using BrowserAuth.valid_admin_password?/1.
Revocation always calls FastCheck.Tickets.Revocation.
Scanner/mobile visibility is updated through the VS-15A path.
Ticket delivery tokens are invalidated through the existing ticket validity model.
StateTransition audit clearly explains who did what, when, and why.
The dashboard never exposes raw provider payloads, plaintext tokens, or unmasked PII by default.
```

---

## 4. Scope

### In scope

```text
Admin Sales review/detail actions for revoking one TicketIssue.
Admin Sales review/detail actions for revoking all tickets on an order.
Manual mark-refunded state transition only after required policy checks.
Manual refund-record note/state tracking if provider refund is external/manual.
Retry-safe use of FastCheck.Tickets.Revocation from VS-15A.
Reason-required operator/admin action forms.
Optional password confirmation for destructive actions.
Masked order/ticket details in LiveView.
StateTransition audit rows for every non-idempotent admin action.
Policy tests for admin vs operator vs customer_session.
Audit and log-redaction tests.
Scanner/mobile regression tests proving revoked tickets are denied.
```

### Out of scope

```text
No Paystack refund API implementation.
No automatic provider refund settlement.
No WhatsApp/customer notification send.
No email send.
No DeliveryAttempt creation.
No resend flow.
No ticket issuance retry implementation.
No new scanner accept/deny logic.
No Redis inventory mutation.
No checkout expiry changes.
No direct mutation of Attendee from LiveView.
No broad raw provider payload viewer.
```

---

## 5. Recommended Files

Use existing repo conventions. If VS-12/VS-13 already created Sales LiveView modules, extend those instead of creating duplicate surfaces.

```text
lib/fastcheck/sales/admin_refunds.ex
lib/fastcheck/sales/admin_revocations.ex
lib/fastcheck_web/live/sales/manual_review_live.ex
lib/fastcheck_web/live/sales/order_show_live.ex
lib/fastcheck_web/live/sales/components/revocation_form_component.ex
lib/fastcheck_web/router.ex
lib/fastcheck/tickets/revocation.ex                  # call only; do not duplicate
lib/fastcheck/sales/state_transition.ex

test/fastcheck/sales/admin_refunds_test.exs
test/fastcheck/sales/admin_revocations_test.exs
test/fastcheck_web/live/sales/manual_review_live_test.exs
test/fastcheck_web/live/sales/order_show_live_test.exs
test/fastcheck/attendees/scan_test.exs
test/fastcheck_web/controllers/mobile/sync_controller_test.exs
```

Recommended route additions under the existing dashboard-auth browser scope:

```text
live "/dashboard/sales/reviews", Sales.ManualReviewLive, :index
live "/dashboard/sales/orders/:id", Sales.OrderShowLive, :show
```

Do not put admin Sales routes outside `[:browser, :dashboard_auth]`.

---

## 6. Admin Action Model

Supported VS-15B actions:

```text
revoke_ticket_issue
revoke_order_tickets
mark_order_refunded_manual
mark_order_cancelled_manual
hold_for_refund_investigation
close_review_no_refund
retry_core_revocation
```

Each action must include:

```text
actor_type
actor_id or current_user.username
reason
correlation_id
request_id if available
idempotency_key
source = "admin_sales_dashboard" or equivalent
```

Sensitive/destructive actions should require:

```text
confirmed_admin_password or equivalent challenge for admin role
explicit checkbox/confirmation text for bulk order-level revocation
```

Operator behavior:

```text
Operators may request/queue review actions only if VS-01F/VS-13 permits.
Operators must not be treated as admins.
Operators must not view raw provider payloads by default.
Operators must not force mark-refunded if policy restricts this to admin.
```

---

## 7. Refund Semantics

VS-15B must be clear about refund meaning.

### Manual refund marker

Allowed in this slice:

```text
mark_order_refunded_manual
mark_ticket_issue_refunded_manual
```

Meaning:

```text
An authorized admin has recorded that refund handling happened externally or is policy-approved.
This is not proof that Paystack processed a refund unless a provider refund integration exists later.
```

### Provider refund

Out of scope:

```text
No Paystack refund endpoint call.
No provider refund status polling.
No automatic reversal settlement.
```

If future provider refund is needed, create a separate provider-refund slice/resource.

### Scanner safety

Refund/cancellation from admin must still call VS-15A:

```text
manual refund/cancel/revoke
  -> revoke TicketIssue(s)
  -> attendee not_scannable
  -> invalidation event
  -> sync aggregator
```

No refunded/cancelled ticket may remain scanner-acceptable.

---

## 8. State Transition Rules

### TicketIssue

Allowed admin-triggered transition:

```text
issued -> revoked
manual_review -> revoked when reason and policy allow
revoked -> revoked idempotent success
```

Forbidden:

```text
revoked -> issued
revoked -> pending
direct DB update without StateTransition
generic update_status
```

### Order

Allowed admin-triggered transitions depend on existing order state:

```text
ticket_issued -> refunded
partially_issued -> refunded | manual_review
paid_verified -> cancelled | manual_review
fulfillment_queued -> cancelled | manual_review
manual_review -> refunded | cancelled | closed_no_action only with reason
expired -> manual_review only if verified late payment/recovery policy exists
```

Forbidden:

```text
awaiting_payment -> refunded without verified payment context
expired -> refunded without verified payment context
cancelled -> ticket_issued via admin UI
refunded -> ticket_issued via admin UI
```

Every state transition must append `FastCheck.Sales.StateTransition`.

---

## 9. UI/UX Requirements

Admin screens must show enough to operate safely without leaking sensitive data.

Show:

```text
order public_reference
order status
payment status summary
verified payment amount/currency
ticket issue status
attendee/scanner status
masked buyer phone/email
last delivery status summary
manual review reason
state transition timeline
```

Mask by default:

```text
buyer_phone
buyer_email
recipient
provider reference where full value is not needed
```

Never show by default:

```text
raw Paystack payload
raw Meta payload
authorization_url
access_code
delivery_token_hash
qr_token_hash
plaintext delivery token
full QR payload internals
```

Required destructive action UX:

```text
reason textarea is mandatory
confirmation checkbox is mandatory for order-level/bulk revocation
password confirmation for admin-only destructive actions if using existing BrowserAuth.valid_admin_password?/1 pattern
preview count of tickets affected before revoke_order_tickets
clear warning: "This will make the ticket non-scannable."
```

---

## 10. Service Boundary

Recommended modules:

```text
FastCheck.Sales.AdminRevocations
FastCheck.Sales.AdminRefunds
```

These modules should:

```text
validate actor and reason
load fresh Sales state
check policy/preconditions
call FastCheck.Tickets.Revocation
append StateTransition
return structured result for LiveView
```

They must not:

```text
mutate Attendee directly
write AttendeeInvalidationEvent directly unless they are inside VS-15A core path
call Paystack
send WhatsApp/email
create DeliveryAttempt
mutate Redis inventory
```

---

## 11. RED/GREEN Test Plan

### RED tests first

```text
RED: admin can revoke a single issued TicketIssue with reason.
RED: revocation calls FastCheck.Tickets.Revocation core path.
RED: linked Attendee becomes not_scannable through VS-15A path.
RED: scanner rejects admin-revoked ticket with TICKET_NOT_SCANNABLE.
RED: mobile sync receives invalidation/event version through existing path.
RED: admin can revoke all issued tickets for an order with confirmation.
RED: order-level revocation is bounded and idempotent under retry.
RED: admin can mark order refunded_manual only after verified payment context exists.
RED: operator cannot perform admin-only refund action.
RED: customer_session cannot access or mutate admin actions.
RED: reason is required for every admin/operator action.
RED: destructive action requires password confirmation if configured.
RED: repeated revoke/refund actions return idempotent result, not duplicate destructive writes.
RED: LiveView masks buyer phone/email by default.
RED: raw provider payloads and token hashes are absent from rendered HTML.
RED: StateTransition timeline records actor, reason, source, correlation_id/idempotency_key.
RED: no Paystack refund API call is made.
RED: no WhatsApp/email/DeliveryAttempt side effect is created.
RED: no Redis inventory mutation occurs.
```

### GREEN targets

```text
GREEN: Admin revocation uses the core VS-15A path only.
GREEN: Admin refund/cancel operations cannot leave scanner-acceptable refunded tickets.
GREEN: Policy boundaries distinguish admin, operator, system, and customer_session.
GREEN: Support UI is useful but safe by default.
GREEN: Audit trail is sufficient for disputes and incident review.
```

---

## 12. Policy Tests

Required policies:

```text
admin can perform revoke/refund actions with reason.
operator can only perform actions explicitly allowed by VS-13/VS-01F.
operator cannot view raw provider payloads by default.
customer_session cannot access LiveView/admin action routes.
system can call underlying service for automated/manual-review recovery if needed.
```

Required field access tests:

```text
operator/admin list views mask phone/email.
raw provider payloads are not rendered by default.
token hashes are not rendered.
plaintext tokens are never present.
```

---

## 13. Failure Modes

| Failure | Required behavior |
|---|---|
| Ticket already revoked | Return idempotent success and refresh UI. |
| Some tickets in order already revoked | Revoke remaining issued tickets; report mixed result. |
| Missing attendee link | Move ticket/order to manual_review or show explicit blocking error. |
| VS-15A core revocation fails | Do not mark admin action successful; keep/manual_review with reason. |
| Event sync aggregator fails | Persist revocation; enqueue/retry sync; show warning status. |
| Cache invalidation fails | Log non-PII warning; DB scanner deny remains authority. |
| Operator attempts admin-only refund | Deny and audit denied attempt if policy requires. |
| Reason missing | Block action before any mutation. |
| Duplicate form submit | Use idempotency key; do not duplicate destructive state. |
| Paystack refund requested by user | State that provider refund is out of this slice; record manual review or future provider-refund task. |

---

## 14. Performance and Scaling Review

### Data placement

```text
Admin dashboard lists: Postgres/Ash query with pagination.
Manual review queue: Postgres indexed by status/manual_review fields.
Revocation action: Postgres durable truth plus VS-10 sync aggregation.
Scanner decision: existing Attendee DB authority + scanner path.
```

### Indexes

Required or verify existing:

```text
sales_orders(event_id, status, inserted_at)
sales_orders(status, updated_at)
sales_orders(public_reference)
sales_ticket_issues(sales_order_id, status)
sales_ticket_issues(attendee_id)
sales_ticket_issues(status, revoked_at)
sales_payment_attempts(sales_order_id, status)
sales_state_transitions(entity_type, entity_id, inserted_at)
attendees(event_id, ticket_code)
attendees(event_id, scan_eligibility)
attendee_invalidation_events(event_id, id)
```

### Cache/Redis/PubSub

```text
No Sales inventory Redis mutation.
No direct mobile scan Redis key mutation.
Call VS-15A/VS-10 helpers only.
Admin LiveView may receive PubSub dashboard refresh events if VS-12/VS-21B conventions exist.
Avoid full-table dashboard refreshes after each action.
```

### Concurrency

```text
Use idempotency_key per admin action request.
Lock TicketIssue/Order rows through the core service.
Bulk order revocation must process bounded ticket batches.
Never rely on LiveView single-click behavior for correctness.
```

---

## 15. Observability

Telemetry names:

```text
[:fastcheck, :sales, :admin, :revocation_requested]
[:fastcheck, :sales, :admin, :revocation_completed]
[:fastcheck, :sales, :admin, :revocation_failed]
[:fastcheck, :sales, :admin, :refund_marked]
[:fastcheck, :sales, :admin, :action_denied]
```

Log allowed:

```text
order_id
ticket_issue_id
attendee_id
event_id
actor_type
actor_id or username
reason_code
correlation_id
idempotency_key
action
result
```

Log forbidden:

```text
buyer_phone
buyer_email
recipient
raw provider payload
authorization_url
access_code
plaintext token
delivery_token_hash
qr_token_hash
full QR payload
```

---

## 16. TOON Coding-Agent Prompt

| Field | Content |
|---|---|
| Task | Implement VS-15B Admin Refund and Revocation Operations in `JCSchoeman96/FastCheckin`. |
| Objective | Add audited admin/operator actions for refund/revocation workflows that call the VS-15A core revocation path and make refunded/cancelled/revoked Sales tickets scanner-non-acceptable without duplicating scanner logic. |
| Output | Sales admin service modules such as `lib/fastcheck/sales/admin_revocations.ex` and `lib/fastcheck/sales/admin_refunds.ex`; LiveView additions under `lib/fastcheck_web/live/sales/`; dashboard-auth routes; tests for permissions, required reasons, idempotency, scanner denial, masked PII, and forbidden side effects. |
| Note | Use existing FastCheckin dashboard auth: routes must be under `[:browser, :dashboard_auth]`; use `BrowserAuth.valid_admin_password?/1` for destructive confirmation if the existing UI pattern supports it. All revocation must call `FastCheck.Tickets.Revocation` from VS-15A; do not mutate Attendee, invalidation rows, or scanner fields directly from LiveView. Required indexes: `sales_orders(event_id,status,inserted_at)`, `sales_ticket_issues(sales_order_id,status)`, `sales_ticket_issues(attendee_id)`, `sales_state_transitions(entity_type,entity_id,inserted_at)`, `attendees(event_id,ticket_code)`, `attendee_invalidation_events(event_id,id)`. Cache/TTL: no new Redis TTLs; no inventory Redis mutation; call VS-15A/VS-10 cache/sync helpers only. PubSub: use existing dashboard refresh conventions if available; no polling. Security: reason required; mask phone/email; never render raw payloads, Paystack access_code/authorization_url, plaintext tokens, token hashes, or QR internals. Forbidden: Paystack refund API, WhatsApp/email sends, DeliveryAttempt creation, direct scanner rewrite, direct Redis inventory/mobile key mutation, generic status update. |
| Success | Admins can safely refund/revoke via audited UI/service actions, operators remain constrained, scanner-visible revocation is guaranteed through VS-15A, duplicate submits are safe, and the dashboard remains PII/token safe. |

---

## 17. Copy-Paste Prompt for Coding Agent

```text
You are implementing FastCheck Sales VS-15B — Admin Refund and Revocation Operations in JCSchoeman96/FastCheckin.

Goal:
Add admin/operator UI and service actions for refund/revocation workflows. These actions must call the VS-15A core revocation path and must not duplicate scanner mutation logic.

Use FastCheckin truths:
- Dashboard routes use `[:browser, :dashboard_auth]`.
- `FastCheckWeb.Plugs.BrowserAuth` assigns the dashboard user and has `valid_admin_password?/1`.
- `FastCheck.Tickets.Revocation` owns scanner-visible revocation from VS-15A.
- `FastCheck.Attendees.Attendee.scan_eligibility = "not_scannable"` is scanner-denied.
- `FastCheck.Attendees.AttendeeInvalidationEvent` is the mobile invalidation path.

Implement:
1. Admin revocation/refund service modules.
2. LiveView actions/forms under the existing Sales admin dashboard pattern.
3. Dashboard-auth routes only.
4. Required reason textarea for every destructive action.
5. Optional password confirmation for admin-only destructive actions.
6. Single-ticket revocation.
7. Order-level bounded revocation.
8. Manual refund marker/state transition only when policy allows.
9. StateTransition audit with actor, reason, correlation_id, idempotency_key, and source.
10. Masked PII and safe support display.

Do not:
- call Paystack refund APIs
- send WhatsApp/email
- create DeliveryAttempt rows
- mutate Redis inventory
- mutate mobile scan Redis keys directly
- modify scanner acceptance logic
- mutate Attendee directly from LiveView
- expose raw provider payloads or token hashes
- use generic update_status

Tests:
- Write RED tests first.
- Prove admin can revoke with reason.
- Prove operator/customer_session forbidden paths.
- Prove missing reason blocks mutation.
- Prove duplicate submit/idempotency safety.
- Prove scanner denies revoked ticket via VS-15A.
- Prove raw payloads/token hashes/PII are not rendered or logged.
- Prove no Paystack/WhatsApp/DeliveryAttempt/Redis inventory side effects.
```

---

## 18. Human Review Checklist

```text
[ ] Admin routes are under [:browser, :dashboard_auth].
[ ] UI uses existing Dashboard/LiveView style.
[ ] Revocation calls FastCheck.Tickets.Revocation only.
[ ] LiveView does not mutate Attendee directly.
[ ] Reason is mandatory.
[ ] Admin/operator permissions are distinct.
[ ] Sensitive action confirmation exists where required.
[ ] StateTransition rows include actor and reason.
[ ] Single-ticket revoke is idempotent.
[ ] Order-level revoke is bounded and idempotent.
[ ] Scanner rejects revoked tickets.
[ ] Mobile sync invalidation path remains intact.
[ ] PII is masked by default.
[ ] Raw provider payloads are not shown by default.
[ ] Token hashes/plaintext tokens are never rendered.
[ ] No Paystack refund API added.
[ ] No WhatsApp/email send added.
[ ] No DeliveryAttempt creation added.
[ ] No Redis inventory mutation added.
[ ] No scanner rewrite added.
```

---

## 19. Next Slice

```text
VS-16 — Meta Cloud API Outbound Client
```
