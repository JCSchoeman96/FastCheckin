# FastCheck Sales Feature Planning Pack — VS-09D Issuance Retry and Partial Failure Tests

**Pack ID:** `0029_VS-09D_issuance-retry-and-partial-failure-tests`  
**Slice:** `VS-09D`  
**Slice name:** Issuance Retry and Partial Failure Tests  
**Version:** `v1.0`  
**Date:** 2026-06-13  
**Status:** QA / hardening pack  
**Primary area:** Tickets / Issuance / Attendees / Retry Safety / Partial Failure  
**Repo truth:** `JCSchoeman96/FastCheckin`  
**Repository path:** `docs/fastcheck_sales/feature_packs/0029_VS-09D_issuance-retry-and-partial-failure-tests`  
**Depends on:** VS-09B, VS-09C, VS-09A, VS-02, VS-07C, VS-08, VS-05, VS-01D, VS-01F, VS-01G, VS-21A  
**Blocks:** VS-10, VS-11, VS-12, VS-15A, VS-15B, VS-19, VS-22  
**Source docs:**

```text
docs/fastcheck_sales/SOURCE_DOCS/FastCheck_Sales_Ash_Atlas_Planning_Pack_v0.2.3_HARDENED.md
docs/fastcheck_sales/SOURCE_DOCS/FastCheck_Sales_Vertical_Slice_Roadmap_v1.1.3_HARDENED.md
```

---

## 1. Purpose

This pack hardens the complete paid-order issuance path built by VS-09B and VS-09C.

It must prove that:

```text
verified paid order
  -> FastCheck.Tickets.Issuer.issue_order/1 or /2
  -> existing Ecto Attendee rows
  -> Sales TicketIssue rows
  -> safe order completion/manual-review outcome
```

is retry-safe under duplicate workers, crashes, partial database writes, constraint races, stale caches, and reconciliation conflicts.

This pack is mostly tests. It may include **minimal implementation fixes** in `FastCheck.Tickets.Issuer` or its private helpers only where required to make the retry/partial-failure tests pass.

---

## 2. FastCheckin Repo Truth Snapshot

The coding agent must treat the current FastCheckin backend as the implementation truth.

Known current structure from GitHub inspection:

```text
Repo: JCSchoeman96/FastCheckin
App: :fastcheck
Module root: FastCheck
Phoenix/Ecto app with Cachex, Redix, Oban, Req, JWT mobile support, telemetry, and Sentry.
```

Known current runtime paths:

```text
lib/fastcheck/attendees.ex
lib/fastcheck/attendees/attendee.ex
lib/fastcheck/attendees/scan.ex
lib/fastcheck/attendees/query.ex
lib/fastcheck/attendees/cache.ex
lib/fastcheck/attendees/reconciliation.ex
lib/fastcheck/attendees/attendee_invalidation_event.ex
lib/fastcheck/attendees/reason_codes.ex
lib/fastcheck/events.ex
lib/fastcheck/events/sync.ex
lib/fastcheck_web/router.ex
lib/fastcheck_web/controllers/mobile/sync_controller.ex
test/fastcheck/attendees/scan_test.exs
test/fastcheck/attendees/reconciliation_test.exs
test/fastcheck_web/controllers/mobile/sync_controller_test.exs
```

Existing scanner and mobile assumptions:

```text
Scanner lookup is event_id + ticket_code.
Attendee unique constraint is unique ticket per event.
scan_eligibility = "not_scannable" is scanner-deny.
Mobile sync exports active or nil scan_eligibility attendees and append-only invalidation events.
Reconciliation can mark active attendees absent from the Tickera authoritative snapshot as not_scannable.
Events.bump_event_sync_version!/1 exists and increments event_sync_version.
```

VS-09D must not rewrite these paths. It must prove the Sales issuance bridge works with them.

---

## 3. Ultimate Outcome

After VS-09D is complete:

```text
Duplicate IssueTicketsWorker executions cannot create duplicate Attendees or TicketIssue rows.
Crashes after Attendee creation but before TicketIssue creation are recoverable.
Crashes after TicketIssue creation but before Order transition are recoverable.
Crashes after some tickets in a multi-ticket order are created are recoverable.
Conflicting Attendee/TicketIssue rows move the order to manual_review instead of overwriting unsafe data.
TicketIssue line_item_sequence uniqueness is proven.
Existing scanner tests remain green.
Existing Tickera reconciliation tests remain green.
Existing mobile sync tests remain green.
No customer ticket delivery starts before issuance is fully safe.
```

The system becomes safe enough for VS-10 Event Sync Version Aggregator and VS-11 Secure Ticket Page to build on it.

---

## 4. Scope

### In scope

```text
Add focused RED/GREEN tests for duplicate issuance retries.
Add focused RED/GREEN tests for partial Attendee creation recovery.
Add focused RED/GREEN tests for partial TicketIssue creation recovery.
Add focused RED/GREEN tests for order transition failure recovery.
Add constraint-race tests for concurrent duplicate workers.
Add tests proving scanner and mobile-sync behavior are not changed by issuance hardening.
Add tests proving Tickera reconciliation protection remains intact for Sales-origin attendees.
Add test seams or dependency injection only where required to simulate failure points cleanly.
Fix issuer idempotency/recovery bugs discovered by the tests.
```

### Out of scope

```text
No new payment logic.
No Paystack HTTP or verification changes.
No WhatsApp / Meta behavior.
No DeliveryAttempt creation.
No customer email delivery.
No secure ticket page.
No QR rendering changes except where VS-08 token/hash generation is already called by VS-09C.
No new inventory reservation or Redis consume/release behavior.
No scanner revocation/refund behavior; VS-15A owns this.
No event sync aggregator implementation; VS-10 owns this.
No admin UI operations.
```

---

## 5. Required Existing Code Confirmation

Before writing tests, the coding agent must confirm these modules and behaviors exist after VS-09B and VS-09C:

```text
FastCheck.Tickets.Issuer.issue_order/1 or issue_order/2
FastCheck.Sales.TicketIssue
FastCheck.Sales.Order
FastCheck.Sales.OrderLine
FastCheck.Sales.StateTransition
FastCheck.Attendees.Attendee
FastCheck.Attendees.Reconciliation
FastCheck.Attendees.Scan
FastCheckWeb.Mobile.SyncController
```

If VS-09B or VS-09C has not been implemented yet, this pack may still add pending/failing tests, but it must be marked blocked for GREEN implementation until those slices exist.

---

## 6. Test Architecture Rules

Prefer tests that exercise the public issuer boundary:

```text
FastCheck.Tickets.Issuer.issue_order(order_id, opts \\ [])
```

Avoid testing private functions directly.

Allowed test support patterns:

```text
Use explicit opts or behaviours to inject failure points in test only.
Use Mox-style behaviours only if the repo already uses Mox or if adding it is approved.
Prefer simple test-only callbacks/options over heavy mocking frameworks.
Use Ecto sandbox carefully for concurrency tests.
Use `async: false` for tests that use concurrent DB processes or Oban-style duplicate execution.
Use DB constraints as the final correctness guard.
```

Recommended test file paths:

```text
test/fastcheck/tickets/issuer_retry_test.exs
test/fastcheck/tickets/issuer_partial_failure_test.exs
test/fastcheck/tickets/issuer_boundary_test.exs
```

If the existing repo uses a different test naming pattern, follow it.

---

## 7. Failure Injection Matrix

The agent must prove these failure points are safe:

| Failure point | Expected retry behavior |
|---|---|
| Before any Attendee row is created | Retry creates all expected Attendees and TicketIssues. |
| After one Attendee row is created | Retry reuses the existing Attendee and creates missing rows. |
| After all Attendee rows are created but before any TicketIssue row | Retry reuses Attendees and creates TicketIssues. |
| After one TicketIssue row is created | Retry reuses existing TicketIssue and creates missing issues. |
| After all TicketIssue rows are created but before Order transition | Retry marks/returns final success without duplicating rows. |
| Duplicate worker starts while first worker is mid-transaction | One succeeds; the other returns idempotent success or safe retry/manual_review without duplicates. |
| Attendee source_reference conflict with different order | Move to manual_review; do not overwrite. |
| TicketIssue unique constraint conflict with different attendee | Move to manual_review; do not overwrite. |
| Event/scanner fields missing or invalid | Fail loudly; do not create invalid scanner rows silently. |
| Tickera reconciliation runs after Sales attendee creation | Sales-created Attendees remain scanner-valid unless explicitly revoked/refunded later. |

---

## 8. Required RED Tests

Write failing tests first.

### Duplicate and idempotency

```text
RED: issue_order/1 called twice creates exactly N Attendees and N TicketIssues for N purchased units.
RED: issue_order/1 called concurrently creates exactly N Attendees and N TicketIssues.
RED: duplicate worker returns idempotent success when order is already fully issued.
RED: duplicate worker does not append duplicate StateTransition rows for the same idempotency key unless the audit model explicitly records duplicate attempts as duplicate events.
```

### Partial Attendee failure

```text
RED: failure after first Attendee creation can retry and reuse the existing Attendee.
RED: failure after all Attendees but before TicketIssues can retry and link all Attendees.
RED: Attendee with same Sales source_reference and same unit is reused.
RED: Attendee with same Sales source_reference but conflicting ownership moves order to manual_review.
```

### Partial TicketIssue failure

```text
RED: failure after first TicketIssue can retry and reuse the existing TicketIssue.
RED: failure after all TicketIssues but before order transition can retry and finish without duplicates.
RED: unique(sales_order_line_id, line_item_sequence) prevents duplicate TicketIssue rows.
RED: unique(attendee_id) where attendee_id is not null prevents one attendee being linked to multiple Sales TicketIssues.
```

### State and audit

```text
RED: order is not marked ticket_issued until all expected TicketIssue rows exist.
RED: partial issue state/manual_review follows VS-09A matrix when some units cannot be recovered.
RED: StateTransition includes correlation_id or idempotency_key.
RED: manual_review transition requires a reason code.
```

### FastCheckin compatibility

```text
RED: existing FastCheck.Attendees.ScanTest remains green.
RED: existing FastCheck.Attendees.ReconciliationTest remains green.
RED: existing FastCheckWeb.Mobile.SyncControllerTest remains green.
RED: issued Sales attendee with scan_eligibility active appears in mobile sync-down.
RED: not_scannable issued attendee is rejected by scanner with TICKET_NOT_SCANNABLE.
```

### Boundary creep

```text
RED: issuer retry tests do not create DeliveryAttempt rows.
RED: issuer retry tests do not send WhatsApp/email.
RED: issuer retry tests do not call Paystack.
RED: issuer retry tests do not mutate Redis inventory.
RED: issuer retry tests do not implement event sync aggregation; only explicit immediate invalidations/caches allowed if already part of VS-09C contract.
```

---

## 9. GREEN Implementation Targets

```text
GREEN: The public issuer entrypoint is retry-safe forever.
GREEN: All partial failure tests pass using deterministic DB-backed idempotency.
GREEN: Duplicate workers cannot produce duplicate attendees, ticket issues, or final order transitions.
GREEN: Conflicting rows are detected and moved to manual_review with reason.
GREEN: StateTransition timeline explains every successful, reused, failed, or manual-review outcome.
GREEN: Existing scanner, reconciliation, and mobile sync tests remain green.
GREEN: Logs contain correlation IDs but no PII, raw payment payloads, Paystack authorization URLs, access codes, plaintext tokens, or full ticket codes.
```

---

## 10. FastCheckin-Specific Compatibility Rules

### Attendee scanner truth

Current Attendee scanner-required fields include:

```text
event_id
ticket_code
payment_status
allowed_checkins
checkins_remaining
scan_eligibility
```

For Sales-issued attendees, expected values are:

```text
payment_status: "completed"
allowed_checkins: 1 unless TicketOffer/OrderLine specifies otherwise
checkins_remaining: allowed_checkins
scan_eligibility: "active"
```

### Reconciliation protection

Current full Tickera reconciliation marks active attendees absent from the import set as `not_scannable`. Sales-origin attendees therefore need protection from VS-02.

VS-09D must prove:

```text
Sales-origin attendees are not marked not_scannable merely because they are absent from Tickera tickets_info.
Tickera-origin attendees still reconcile exactly as before.
Reconciliation still writes invalidation rows for Tickera-origin absences.
```

### Mobile sync

Current mobile sync exports active/nil scan_eligibility attendees and invalidation events.

VS-09D must prove:

```text
Sales-issued active attendees appear in sync-down.
Sales-issued not_scannable attendees do not appear in active attendee payload and are represented through invalidation flow once VS-15A implements revocation.
```

Do not implement VS-15A behavior here.

---

## 11. Required Indexes and DB Constraints to Verify

These should already exist from VS-01G, VS-02, VS-09B, and VS-09C. VS-09D must test them or assert migrations contain them.

```text
attendees: unique(event_id, ticket_code) as existing unique_ticket_per_event
attendees: unique(source, source_reference) where source = 'fastcheck_sales' or equivalent
attendees: index(event_id, source) or equivalent for reconciliation protection
sales_ticket_issues: unique(ticket_code)
sales_ticket_issues: unique(sales_order_line_id, line_item_sequence)
sales_ticket_issues: unique(attendee_id) where attendee_id is not null
sales_ticket_issues: index(sales_order_id)
sales_ticket_issues: index(status)
sales_state_transitions: index(entity_type, entity_id, inserted_at)
```

If a required index is absent, the agent may add the minimal migration required by the owning previous slice contract, but must report that VS-09D had to fix an earlier-slice gap.

---

## 12. Performance and Scaling Review

### Data layers

```text
Hot path: scanner reads and check-ins remain existing FastCheckin runtime path.
Warm path: attendee Cachex/ETS must be invalidated only when required by existing cache rules.
Cold/durable: Attendee, TicketIssue, Order, StateTransition in Postgres.
Redis: no inventory mutation in this slice.
Oban: duplicate worker safety must not rely on Oban uniqueness alone.
```

### 100k-concurrency safety

VS-09D protects the post-payment fulfillment spike path.

Rules:

```text
DB unique constraints are mandatory.
Order/advisory locks are mandatory where selected by VS-09A.
No large attendee table scans.
All reuse lookups must use indexed source_reference or ticket_issue identity.
No external HTTP inside issuance transaction.
No QR rendering inside hot transaction if token/code generation can be done before/after safely.
Failure injection tests must prove bounded retry behavior.
```

### Cache invalidation

```text
When Attendee rows are created, invalidate attendee lookup/list caches for that event if existing cache layer would otherwise serve stale mobile/admin/scanner data.
Do not broadcast customer-facing delivery events.
Do not implement VS-10 event sync aggregation here.
```

---

## 13. Security and Logging Rules

```text
Do not log buyer_phone.
Do not log buyer_email.
Do not log raw provider payloads.
Do not log Paystack authorization_url or access_code.
Do not log plaintext delivery tokens.
Do not log plaintext QR tokens.
Do not log full ticket_code in production logs unless existing scanner logs already do; prefer truncated/redacted ticket refs.
Use correlation_id, order public_reference, idempotency_key, and counts for diagnostics.
Manual-review reason codes must be stable strings, not ad-hoc messages.
```

---

## 14. Failure Modes and Required Outcomes

| Failure | Required outcome |
|---|---|
| Duplicate worker | Exact same final rows; no duplicates. |
| Crash after attendee create | Retry reuses attendee. |
| Crash after ticket issue create | Retry reuses TicketIssue. |
| Crash before order transition | Retry completes transition if all rows exist. |
| Conflicting attendee identity | manual_review, no overwrite. |
| Conflicting ticket issue identity | manual_review, no overwrite. |
| Reconciliation conflict | Sales-origin attendees protected; Tickera-origin behavior unchanged. |
| Cache stale after attendee create | Existing cache invalidation called or test documents why it is not needed. |
| Mobile sync after issue | Active Sales attendee appears in sync-down. |
| Scanner after issue | Active Sales attendee follows normal scanner behavior. |
| Scanner after not_scannable fixture | Denied with existing `TICKET_NOT_SCANNABLE` behavior. |

---

## 15. TOON Coding-Agent Prompt

| Field | Content |
|---|---|
| Task | Add VS-09D issuance retry and partial-failure tests for the FastCheck Sales issuer path in `JCSchoeman96/FastCheckin`. |
| Objective | Prove the combined VS-09B/VS-09C issuance path is safe under duplicate workers, crashes, partial writes, and reconciliation/scanner/mobile-sync compatibility before any delivery, WhatsApp, or secure ticket page work begins. |
| Output | New tests under `test/fastcheck/tickets/` or repo-equivalent; minimal issuer hardening in `lib/fastcheck/tickets/issuer.ex` only if tests expose gaps; optional minimal migration only if a required prior-slice constraint is missing; final report listing tested failure points, DB constraints, cache invalidation behavior, and unchanged scanner/reconciliation/mobile behavior. |
| Note | Repo truth is `JCSchoeman96/FastCheckin`, module root `FastCheck`. Existing Attendee schema is `FastCheck.Attendees.Attendee`; scanner denies `scan_eligibility = "not_scannable"`; mobile sync exports active/nil scan_eligibility attendees; Tickera reconciliation marks absent active tickets not_scannable and writes invalidation events. Do not migrate Attendees to Ash. Do not create DeliveryAttempt rows. Do not send WhatsApp/email. Do not call Paystack. Do not mutate Redis inventory. Do not implement VS-10 sync aggregation or VS-15A revocation. Required indexes/constraints: `unique(event_id,ticket_code)`, Sales-origin unique attendee key, `unique(sales_order_line_id,line_item_sequence)`, `unique(attendee_id)` for TicketIssue. Use DB uniqueness and order/advisory locks; Oban uniqueness alone is not enough. Tests using concurrent processes must be `async: false` and handle SQL sandbox correctly. Logs must redact PII and tokens. |
| Success | Running the VS-09D test suite proves retries are idempotent, partial failures are recoverable, conflicts move to manual_review, and existing scanner/reconciliation/mobile-sync tests remain green. |

---

## 16. Copy-Paste Prompt for Coding Agent

```text
You are implementing FastCheck Sales VS-09D — Issuance Retry and Partial Failure Tests.

Use the FastCheckin repo as truth:
- Repo: JCSchoeman96/FastCheckin
- Module root: FastCheck
- Existing attendee schema: FastCheck.Attendees.Attendee
- Existing scanner mutation path: FastCheck.Attendees.Scan
- Existing Tickera reconciliation: FastCheck.Attendees.Reconciliation
- Existing mobile sync: FastCheckWeb.Mobile.SyncController

Goal:
Prove the combined VS-09B + VS-09C issuer path is idempotent and recoverable under duplicate workers and partial failures.

Write RED tests first. Use the public issuer entrypoint:
FastCheck.Tickets.Issuer.issue_order(order_id, opts \\ [])

Add tests for:
1. Duplicate issue_order calls create exactly one Attendee and one TicketIssue per purchased unit.
2. Concurrent duplicate workers create no duplicates.
3. Crash after one Attendee creation retries and reuses that Attendee.
4. Crash after all Attendees but before TicketIssue creation retries and links all attendees.
5. Crash after one TicketIssue creation retries and reuses that TicketIssue.
6. Crash after all TicketIssues but before order transition retries and completes safely.
7. Conflicting Attendee or TicketIssue identity moves order to manual_review.
8. Order cannot be ticket_issued unless all expected TicketIssue rows exist.
9. Existing scanner tests remain green.
10. Existing reconciliation tests remain green.
11. Existing mobile sync tests remain green.
12. No DeliveryAttempt, WhatsApp, Paystack, Redis inventory, or scanner revocation behavior is added.

You may add small test-only failure injection seams to the issuer if needed, but do not over-engineer.
Use DB constraints and locks as final correctness guards.
Do not rely on Oban uniqueness alone.
Keep transactions small and do not perform external HTTP inside transactions.

Final report must list:
- failure points tested
- DB constraints relied on
- cache invalidation behavior
- scanner/mobile/reconciliation compatibility results
- any earlier-slice gaps that had to be fixed
```

---

## 17. Human Review Checklist

```text
[ ] Tests use FastCheckin repo/module names, not vg_app.
[ ] Tests target public issuer boundary, not private helpers.
[ ] Duplicate sequential retry test passes.
[ ] Duplicate concurrent worker test passes.
[ ] Partial attendee failure retry test passes.
[ ] Partial TicketIssue failure retry test passes.
[ ] Order transition failure retry test passes.
[ ] Conflicting rows move to manual_review.
[ ] No duplicate Attendees.
[ ] No duplicate TicketIssues.
[ ] No duplicate unsafe StateTransition rows.
[ ] Existing ScanTest remains green.
[ ] Existing ReconciliationTest remains green.
[ ] Existing Mobile SyncController tests remain green.
[ ] Cache invalidation behavior is verified or explicitly documented.
[ ] No Paystack/WhatsApp/DeliveryAttempt/Redis inventory changes.
[ ] Logs are PII/token safe.
[ ] Any missing index/constraint was reported as earlier-slice gap.
```

---

## 18. Next Slice

```text
VS-10 — Event Sync Version Aggregator
```
