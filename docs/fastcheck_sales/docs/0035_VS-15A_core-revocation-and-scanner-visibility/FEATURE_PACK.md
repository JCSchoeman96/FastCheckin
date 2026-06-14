# FastCheck Sales Feature Planning Pack — VS-15A Core Revocation and Scanner Visibility

**Pack ID:** `0035_VS-15A_core-revocation-and-scanner-visibility`  
**Slice:** `VS-15A`  
**Slice name:** Core Revocation and Scanner Visibility  
**Version:** `v1.0`  
**Date:** 2026-06-13  
**Status:** Implementation-ready safety slice, dependent on VS-09D and VS-10  
**Primary area:** Sales / TicketIssue / Existing Attendees / Scanner Visibility / Mobile Sync  
**Repo truth:** `JCSchoeman96/FastCheckin`  
**Repository path:** `docs/fastcheck_sales/feature_packs/0035_VS-15A_core-revocation-and-scanner-visibility/`  
**Source docs:** `docs/fastcheck_sales/SOURCE_DOCS/FastCheck_Sales_Ash_Atlas_Planning_Pack_v0.2.3_HARDENED.md`, `docs/fastcheck_sales/SOURCE_DOCS/FastCheck_Sales_Vertical_Slice_Roadmap_v1.1.3_HARDENED.md`  
**Normalization:** Batch `0035_0037`, normalized 2026-06-14  
**Depends on:** VS-09D, VS-10, VS-08, VS-09C, VS-00A, VS-00B, VS-01F, VS-21A  
**Blocks:** VS-15B, VS-20, VS-21B, VS-22, VS-23B, paid-event launch  

---

## 1. Purpose

Implement the **core backend revocation path** that makes Sales-issued tickets scanner-non-acceptable without relying on admin UI.

This slice ensures that when a Sales ticket is revoked, refunded, or cancelled at the backend level:

```text
TicketIssue becomes revoked
existing FastCheck Attendee becomes scan_eligibility = "not_scannable"
AttendeeInvalidationEvent is appended
event mobile sync version aggregation is triggered
ticket delivery token access is made invalid
scanner/mobile paths deny the ticket
StateTransition audit records the reason
```

Critical principle:

```text
VS-15A is core safety behavior.
VS-15A must not depend on VS-15B admin refund/revocation UI.
VS-15A must not call Paystack refund APIs.
VS-15A must not send WhatsApp/email notifications.
VS-15A must not rewrite scanner acceptance logic unless tests prove a tiny compatibility hook is required.
```

---

## 2. FastCheckin Current-State Findings

The implementation must use the current FastCheckin scanner model.

Observed repo truth:

```text
Existing attendee schema: FastCheck.Attendees.Attendee
Existing scanner mutation path: FastCheck.Attendees.Scan
Existing invalidation model: FastCheck.Attendees.AttendeeInvalidationEvent
Existing reason-code module: FastCheck.Attendees.ReasonCodes
Existing mobile hot-state DB authority check: FastCheck.Scans.HotState.DbAuthority
Existing mobile sync/down path: FastCheckWeb.Mobile.SyncController
Existing event sync version field: FastCheck.Events.Event.event_sync_version
```

Important existing behavior:

```text
Attendee has scan_eligibility, ineligibility_reason, ineligible_since, source_last_seen_at, and last_authoritative_sync_run_id.
Scanner code already treats scan_eligibility = "not_scannable" as denied.
AttendeeInvalidationEvent is already the append-only mobile tombstone model.
ReasonCodes already has source_missing_from_authoritative_sync and revoked.
DbAuthority checks Postgres before Redis/Lua mobile hot-state decisions, so a stale Redis snapshot can still be denied by DB authority.
```

Therefore the right VS-15A implementation is:

```text
update scanner-visible Attendee state
append invalidation
trigger sync aggregation
invalidate caches
do not rewrite scanner core
```

---


### Repo-specific scanner authority guardrail

```text
Do not add attendees.scanner_status.
Do not introduce a second scanner-authority field.
Existing FastCheck scanner/mobile truth remains:
- Attendee.scan_eligibility
- Attendee.ineligibility_reason
- Attendee.ineligible_since
- Attendee.source_last_seen_at
- Attendee.last_authoritative_sync_run_id

Sales TicketIssue.status may record Sales-side validity/audit state, but scanner/mobile acceptance must be projected through the existing Attendee scan_eligibility path.
```

## 3. Ultimate Outcome

After VS-15A:

```text
A revoked Sales TicketIssue is immediately scanner-denied.
A refunded Sales TicketIssue is immediately scanner-denied.
A cancelled Sales TicketIssue is immediately scanner-denied.
Mobile sync clients receive an invalidation event and updated event_sync_version.
Stale Redis mobile snapshots are safely overridden by FastCheck.Scans.HotState.DbAuthority.
Secure ticket pages stop presenting revoked tickets as usable.
Retries are idempotent.
Duplicate workers cannot generate duplicate invalidation/audit rows beyond the approved idempotency contract.
Admin UI in VS-15B can call this core path instead of inventing its own scanner mutation behavior.
```

---

## 4. Scope

### In scope

```text
Create the core revocation service module.
Add or finalize TicketIssue named revocation actions.
Update existing Attendee scan_eligibility to not_scannable.
Set ineligibility_reason using FastCheck.Attendees.ReasonCodes.
Set ineligible_since.
Append AttendeeInvalidationEvent.
Trigger VS-10 event sync version aggregation.
Invalidate existing attendee caches.
Revoke or invalidate active ticket delivery-token access.
Append StateTransition records.
Add RED/GREEN scanner, mobile sync, idempotency, cache, and policy tests.
```

### Out of scope

```text
No Paystack refund API calls.
No refund provider state machine implementation.
No admin refund/revocation UI.
No WhatsApp/email notification.
No DeliveryAttempt creation.
No resend behavior.
No customer support message flow.
No broad scanner rewrite.
No Redis inventory mutation.
No checkout/order expiry changes.
No TicketIssue creation.
```

---

## 5. Recommended Files

Use existing project naming conventions. If equivalent files already exist, extend them minimally.

```text
lib/fastcheck/tickets/revocation.ex
lib/fastcheck/tickets/scanner_visibility.ex
lib/fastcheck/workers/revoke_ticket_worker.ex              # only if async worker is selected
lib/fastcheck/sales/ticket_issue.ex
lib/fastcheck/sales/order.ex
lib/fastcheck/sales/state_transition.ex
lib/fastcheck/attendees/reason_codes.ex
test/fastcheck/tickets/revocation_test.exs
test/fastcheck/tickets/scanner_visibility_test.exs
test/fastcheck/attendees/reconciliation_test.exs
test/fastcheck/attendees/scan_test.exs
test/fastcheck_web/controllers/mobile/sync_controller_test.exs
```

Do not move existing Attendee, Scan, Reconciliation, or mobile sync modules into Ash.

---

## 6. Public API Contract

Preferred module:

```text
FastCheck.Tickets.Revocation
```

Required public functions:

```text
revoke_ticket_issue(ticket_issue_id, opts \\ [])
revoke_order_tickets(order_id, opts \\ [])
```

Allowed opts:

```text
:reason                 # required, stable reason atom/string
:actor_type             # system/admin/operator
:actor_id
:correlation_id
:idempotency_key
:source                 # refund, cancel, manual_review, system_reconciliation
:revoked_at             # optional override for tests
```

Return shapes:

```text
{:ok, %{ticket_issue_id: id, attendee_id: id, status: :revoked}}
{:ok, %{ticket_issue_id: id, attendee_id: id, status: :already_revoked}}
{:error, :not_found}
{:error, :invalid_state}
{:error, {:missing_attendee, ticket_issue_id}}
{:error, {:conflict, reason}}
```

Rules:

```text
The public API must be idempotent.
Calling revoke twice for the same TicketIssue returns already_revoked or equivalent success.
Do not expose raw token hashes or full ticket code values in logs.
Do not use buyer email/phone in idempotency keys.
```

---

## 7. State Transition Rules

### TicketIssue

Allowed minimum transition:

```text
issued -> revoked
manual_review -> revoked only with explicit admin/system recovery rule
revoked -> revoked idempotent no-op
pending -> revoked only if the ticket was never scanner-visible and the reason is cancellation/cleanup
```

Forbidden:

```text
revoked -> issued
revoked -> pending
issued -> manual hidden DB update without StateTransition
```

### Order

VS-15A may support order-level derived transitions only when all issued tickets are revoked.

Allowed:

```text
ticket_issued -> refunded       # only when refund/revocation path is called by later VS-15B/provider flow
ticket_issued -> manual_review  # when revocation partially fails
partially_issued -> manual_review
```

Preferred for this slice:

```text
Keep order-level refund/cancel mutations minimal.
Focus on ticket-level scanner visibility.
VS-15B owns admin refund/revocation operations and broader order state controls.
```

---

## 8. Attendee Scanner-Visibility Contract

Every revoked Sales ticket linked to an existing Attendee must update:

```text
scan_eligibility = "not_scannable"
ineligibility_reason = FastCheck.Attendees.ReasonCodes.revoked() or a new stable Sales-specific reason code
ineligible_since = now
updated_at = now
```

If adding Sales-specific reason codes, add them centrally:

```text
FastCheck.Attendees.ReasonCodes.sales_revoked()
FastCheck.Attendees.ReasonCodes.sales_refunded()
FastCheck.Attendees.ReasonCodes.sales_cancelled()
```

Do not scatter magic strings.

Minimum implementation can use existing:

```text
ReasonCodes.revoked()
```

if the team wants a smaller first slice.

---

## 9. AttendeeInvalidationEvent Contract

For every scanner-visible revocation, append one invalidation event:

```text
event_id
attendee_id
ticket_code
change_type = "ineligible"
reason_code
effective_at
source_sync_run_id
inserted_at
```

Rules:

```text
Use one invalidation event per attendee/ticket becoming not_scannable.
If the same TicketIssue is already revoked and the same Attendee already not_scannable, return idempotent success.
Avoid duplicate invalidation rows on repeated identical retries if a unique/idempotency convention exists.
If no such convention exists, still ensure duplicate retries do not create multiple state transitions or repeated destructive mutations.
Do not delete invalidation rows.
```

Recommended idempotency options:

```text
Prefer a StateTransition/idempotency_key guard for revocation workflow.
Optionally add an invalidation metadata/idempotency mechanism only if current schema supports it cleanly.
Do not over-engineer the invalidation table if append-only semantics are accepted.
```

---

## 10. Event Sync and Cache Rules

VS-15A must trigger scanner/mobile visibility after revocation.

Required:

```text
Use the VS-10-approved event sync version aggregator after successful revocation.
Invalidate attendee cache for the event/ticket.
Invalidate event attendee list cache.
Do not directly bump event_sync_version in multiple places if the aggregator exists.
Do not cause one bump per ticket for bulk revocations if the aggregator can debounce/batch by event_id.
```

FastCheckin cache paths to respect:

```text
FastCheck.Attendees.invalidate_attendees_by_event_cache(event_id)
FastCheck.Cache.EtsLayer.delete_attendee(event_id, ticket_code)
FastCheck.Cache.EtsLayer.invalidate_attendees(event_id)
```

Redis hot-state note:

```text
The existing mobile hot-state path uses FastCheck.Scans.HotState.DbAuthority to reject not_scannable tickets before Redis/Lua decisions.
Therefore immediate scanner denial must rely on Postgres attendee scan_eligibility plus DbAuthority.
If VS-10 added a Redis hot-state version invalidation helper, call that helper.
Do not mutate FastCheck.Scans.HotState.Keyspace keys directly from revocation code.
```

---

## 11. Secure Ticket Page / Token Rules

When a TicketIssue is revoked:

```text
TicketIssue.status = revoked
existing Attendee.scan_eligibility = "not_scannable" through the VS-15A revocation path
no attendees.scanner_status field may be introduced; Attendee.scan_eligibility remains scanner/mobile truth
delivery_token_hash remains hashed but must no longer authorize active ticket display
delivery_token_expires_at may be set to now if this matches VS-08/VS-11 policy
revoked_at is set
revocation_reason is set
```

Secure ticket page behavior:

```text
A revoked TicketIssue token lookup must show "ticket no longer valid" or equivalent.
It must not show a scannable QR as valid.
It must not leak revocation internals or provider payload details.
It must not expose raw token hashes.
```

---

## 12. RED/GREEN Test Plan

### RED tests first

```text
RED: revoke_ticket_issue/2 changes TicketIssue issued -> revoked.
RED: revoke_ticket_issue/2 sets linked Attendee scan_eligibility to not_scannable.
RED: scanner check_in/4 rejects the revoked attendee with TICKET_NOT_SCANNABLE.
RED: mobile DbAuthority rejects the revoked attendee even if Redis hot snapshot exists.
RED: AttendeeInvalidationEvent is appended with change_type ineligible and reason_code.
RED: event sync version aggregation is triggered once for the event.
RED: attendee/event caches are invalidated.
RED: secure ticket page no longer shows a revoked token as active.
RED: duplicate revoke_ticket_issue/2 call is idempotent.
RED: duplicate worker execution is safe.
RED: revoking a TicketIssue with missing attendee moves to manual_review or returns explicit error without silently succeeding.
RED: revoking a TicketIssue not belonging to the event/attendee pair fails with conflict.
RED: revoked/refunded/cancelled reasons are stable reason codes, not scattered magic strings.
RED: logs do not include buyer_email, buyer_phone, raw token, delivery_token_hash, qr_token_hash, or raw provider payload.
RED: customer_session actor cannot revoke.
RED: operator/admin revocation requires an audit reason.
RED: no Paystack, WhatsApp, DeliveryAttempt, or Redis inventory behavior is called.
```

### GREEN targets

```text
GREEN: Core revocation service updates Sales TicketIssue and existing Attendee in one safe workflow.
GREEN: Existing FastCheck scanner path denies revoked tickets without scanner rewrite.
GREEN: Mobile sync gets invalidation and event sync visibility.
GREEN: Retry and duplicate workers are safe.
GREEN: Admin UI can call this path later in VS-15B.
GREEN: Paid launch can rely on backend scanner-safe revocation.
```

---

## 13. Policy Tests

Required actor behavior:

```text
system can revoke with reason.
admin can revoke with reason.
operator can request allowed revocation only if VS-01F/VS-13 permits it.
customer_session cannot revoke.
unauthenticated actor cannot revoke.
admin/operator cannot access raw provider payloads through this path.
```

Required audit behavior:

```text
Manual/admin/operator revocations require a non-empty reason.
System revocations require correlation_id or idempotency_key when available.
Every non-idempotent status change appends StateTransition.
```

---

## 14. Failure Modes

| Failure | Required behavior |
|---|---|
| TicketIssue already revoked | Idempotent success; no duplicate destructive state. |
| Attendee already not_scannable | Idempotent success if linked to same TicketIssue. |
| Attendee missing | Mark TicketIssue/order manual_review or return explicit error; do not pretend scanner was updated. |
| TicketIssue attendee_id conflicts with ticket_code/event_id | Manual review/conflict error; do not mutate unrelated attendee. |
| DB lock contention | Retry through Oban or return retryable error. |
| Event sync aggregator unavailable | Revocation still persists; enqueue/retry sync aggregation; manual alert if repeated. |
| Cache invalidation fails | Log non-PII warning; do not roll back revocation if DB scanner deny is committed. |
| Duplicate worker runs | Safe idempotent result. |
| Secure ticket token still valid after revoke | Test must fail; page must derive validity from TicketIssue status. |

---

## 15. Performance and Scaling Review

### Data placement

```text
Hot scanner decision: existing DB-authority check + scanner path.
Warm mobile hot state: existing Redis mobile scan snapshot.
Cold durable truth: Postgres Attendee + Sales TicketIssue + StateTransition.
```

### Redis

```text
Do not mutate sales inventory Redis in this slice.
Do not mutate mobile scan Redis keyspace directly.
If VS-10 provides a hot-state invalidation helper, use it.
Otherwise rely on DbAuthority for immediate deny and event sync invalidation for mobile sync-down.
```

### Cache

```text
Invalidate ETS attendee key {event_id, ticket_code}.
Invalidate event attendee list Cachex key.
Avoid loading all attendees for an event during bulk revocation.
```

### Indexes

Required existing or new indexes:

```text
sales_ticket_issues(attendee_id)
sales_ticket_issues(ticket_code)
sales_ticket_issues(status, revoked_at)
sales_ticket_issues(sales_order_id, status)
attendees(event_id, ticket_code) unique existing constraint
attendees(event_id, scan_eligibility)
attendee_invalidation_events(event_id, id)
attendee_invalidation_events(attendee_id)
sales_state_transitions(entity_type, entity_id, inserted_at)
```

### Concurrency

```text
Use row locks on TicketIssue and Attendee.
Use idempotency_key when revocation is worker-triggered.
Do not rely on Oban uniqueness alone.
Bulk revoke must process bounded batches and trigger one sync aggregation per event window, not one expensive global refresh per ticket.
```

---

## 16. Observability

Telemetry names:

```text
[:fastcheck, :sales, :ticket, :revocation_started]
[:fastcheck, :sales, :ticket, :revoked]
[:fastcheck, :sales, :ticket, :revocation_idempotent]
[:fastcheck, :sales, :ticket, :revocation_failed]
[:fastcheck, :sales, :scanner_visibility, :invalidation_appended]
[:fastcheck, :sales, :scanner_visibility, :sync_queued]
```

Log rules:

```text
Log ticket_issue_id, attendee_id, event_id, actor_type, correlation_id, reason_code.
Do not log buyer_email, buyer_phone, raw tokens, token hashes, QR payloads, raw provider payloads, Paystack access_code, or authorization_url.
Avoid full ticket_code in info logs; if needed for debug, use a redacted helper.
```

---

## 17. TOON Coding-Agent Prompt

| Field | Content |
|---|---|
| Task | Implement VS-15A Core Revocation and Scanner Visibility in `JCSchoeman96/FastCheckin`. |
| Objective | Make revoked/refunded/cancelled Sales tickets scanner-non-acceptable through the existing FastCheck Attendee, invalidation, and mobile sync path without relying on admin UI. |
| Output | `lib/fastcheck/tickets/revocation.ex`; optional `lib/fastcheck/tickets/scanner_visibility.ex`; minimal additions to `FastCheck.Attendees.ReasonCodes`; TicketIssue named revocation actions; tests for scanner denial, mobile sync invalidation, idempotency, cache invalidation, policies, log redaction, and boundary creep. |
| Note | Use existing `FastCheck.Attendees.Attendee.scan_eligibility`; set it to `"not_scannable"` with stable reason code and `ineligible_since`. Append `FastCheck.Attendees.AttendeeInvalidationEvent` with `change_type="ineligible"`. Use VS-10 event sync version aggregator, not ad-hoc scattered bumps. Use existing cache invalidation helpers; do not mutate Redis inventory or mobile scan Redis keyspace directly. `FastCheck.Scans.HotState.DbAuthority` already rejects not_scannable attendees, so do not rewrite scanner/Lua logic. Required indexes: `sales_ticket_issues(attendee_id)`, `sales_ticket_issues(status, revoked_at)`, `attendees(event_id, ticket_code)`, `attendees(event_id, scan_eligibility)`, `attendee_invalidation_events(event_id,id)`, `state_transitions(entity_type,entity_id,inserted_at)`. Cache rules: invalidate ETS `{event_id,ticket_code}` and event attendee list; sync aggregation debounced by event_id. TTL/Redis: no Sales inventory Redis mutation; no direct mobile hot-state Redis mutation; rely on DbAuthority plus sync aggregator. PubSub: broadcast/admin status only if existing VS-10/VS-12 convention exists. Security: reason required for admin/operator; no raw provider payloads or plaintext/hash tokens in logs. Forbidden: Paystack refund API, WhatsApp/email sends, DeliveryAttempt creation, admin UI mutation, Attendee migration to Ash, direct scanner rewrite, generic status update. |
| Success | A revoked TicketIssue becomes scanner-denied immediately, mobile sync receives an invalidation, secure ticket page stops treating the ticket as active, duplicate retries are safe, and VS-15B can use this core path for admin refund/revoke operations. |

---

## 18. Copy-Paste Prompt for Coding Agent

```text
You are implementing FastCheck Sales VS-15A — Core Revocation and Scanner Visibility in JCSchoeman96/FastCheckin.

Goal:
Make Sales-issued tickets scanner-non-acceptable when revoked/refunded/cancelled, through the existing FastCheck Attendee + invalidation + mobile sync path.

Use these current FastCheckin truths:
- Attendee is `FastCheck.Attendees.Attendee`.
- Scanner-visible deny field is `scan_eligibility = "not_scannable"`.
- Existing reason codes live in `FastCheck.Attendees.ReasonCodes`.
- Existing invalidation table/schema is `FastCheck.Attendees.AttendeeInvalidationEvent`.
- Existing scanner/hot-state DB authority already rejects not_scannable attendees.
- Existing event sync version behavior must be triggered through the VS-10 aggregator.

Implement:
1. `FastCheck.Tickets.Revocation.revoke_ticket_issue(ticket_issue_id, opts \\ [])`.
2. Optional `revoke_order_tickets(order_id, opts \\ [])` for bounded order-level use.
3. TicketIssue named action/transition to `revoked`.
4. Attendee update to `scan_eligibility = "not_scannable"`, stable `ineligibility_reason`, and `ineligible_since`.
5. Append an `AttendeeInvalidationEvent`.
6. Trigger VS-10 event sync version aggregation.
7. Invalidate existing attendee caches.
8. Make duplicate revocation idempotent.
9. Make missing/conflicting attendee references explicit errors/manual_review.
10. Keep logs redacted.

Do not:
- call Paystack refund APIs
- send WhatsApp/email
- create DeliveryAttempt rows
- mutate Redis inventory
- mutate mobile scan Redis keyspace directly
- rewrite scanner acceptance logic
- hide Attendee mutation inside Ash resource actions
- use generic update_status
- store/log plaintext tokens or token hashes

Tests:
- Write RED tests first.
- Prove scanner check-in rejects revoked tickets with TICKET_NOT_SCANNABLE.
- Prove mobile DbAuthority rejects revoked tickets even with stale Redis hot state.
- Prove AttendeeInvalidationEvent is appended.
- Prove event sync aggregation is called.
- Prove secure ticket page treats revoked token as invalid.
- Prove duplicate worker/retry safety.
- Prove customer_session cannot revoke.
- Prove admin/operator/system revocation requires audit reason where applicable.
- Prove no Paystack/WhatsApp/DeliveryAttempt/Redis inventory behavior is called.
```

---

## 19. Human Review Checklist

```text
[ ] Implementation is in FastCheckin repo.
[ ] Existing Attendee schema was not migrated to Ash.
[ ] Revocation service uses existing Attendee scan_eligibility.
[ ] Reason codes are central and stable.
[ ] AttendeeInvalidationEvent row is appended.
[ ] Event sync version aggregator is triggered once per event window.
[ ] Cache invalidation is present.
[ ] Scanner tests deny revoked ticket.
[ ] Mobile sync/DbAuthority tests deny revoked ticket.
[ ] Secure ticket page no longer displays active QR for revoked ticket.
[ ] Duplicate worker/retry is idempotent.
[ ] Missing/conflicting attendee references do not silently succeed.
[ ] StateTransition is appended for non-idempotent state changes.
[ ] Admin/operator reason is required.
[ ] No Paystack refund API was added.
[ ] No WhatsApp/email delivery was added.
[ ] No DeliveryAttempt rows are created.
[ ] No Redis inventory mutation exists.
[ ] No direct mobile scan Redis key mutation exists.
[ ] Logs are PII/token safe.
```

---

## 20. Next Slice

```text
VS-15B — Admin Refund and Revocation Operations
```
