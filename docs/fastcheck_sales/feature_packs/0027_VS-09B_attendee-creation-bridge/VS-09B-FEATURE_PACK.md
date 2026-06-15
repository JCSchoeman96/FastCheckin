# FastCheck Sales Feature Planning Pack — VS-09B Attendee Creation Bridge

**Pack ID:** `0027_VS-09B_attendee-creation-bridge`  
**Slice:** `VS-09B`  
**Slice name:** Attendee Creation Bridge  
**Version:** `v1.1 CORRECTED`  
**Date:** 2026-06-13  
**Status:** Implementation-facing bridge pack  
**Repository inspected:** `JCSchoeman96/FastCheckin`  
**Primary area:** Tickets / Existing Ecto Attendees / Scanner Compatibility / Tickera Reconciliation  
**Depends on:** VS-02, VS-09A, VS-07C, VS-08, VS-05, VS-01D, VS-01F, VS-01G, VS-00A, VS-00B, VS-21A  
**Blocks:** VS-09C, VS-09D, VS-10, VS-11, VS-12, VS-15A, VS-15B, VS-19, VS-22  
**Repository path:** `docs/fastcheck_sales/feature_packs/0027_VS-09B_attendee-creation-bridge/`  
**Source docs:**

```text
docs/fastcheck_sales/SOURCE_DOCS/FastCheck_Sales_Ash_Atlas_Planning_Pack_v0.2.3_HARDENED.md
docs/fastcheck_sales/SOURCE_DOCS/FastCheck_Sales_Vertical_Slice_Roadmap_v1.1.3_HARDENED.md
```

**Normalization:** Batch `0026_0028`; structural normalization only; source docs are repo-relative; no semantic changes applied.  

---

## 0. Correction Notice

This pack supersedes the earlier VS-09B draft that inspected `vg_app` by mistake.

The correct backend repo is:

```text
JCSchoeman96/FastCheckin
```

Do not use `vg_app` repository assumptions for this slice.

**Normalization:** Batch `0026_0028`; structural normalization only; source docs are repo-relative; no semantic changes applied.  

---

## 1. Purpose

Implement the Attendee-creation bridge for paid FastCheck Sales orders.

The bridge must create **existing Ecto `FastCheck.Attendees.Attendee` rows** from verified Sales orders through the approved issuer boundary:

```text
FastCheck.Tickets.Issuer.issue_order(order_id, opts \ [])
```

VS-09B creates or reuses Attendee rows only. VS-09C creates the Sales-side `TicketIssue` audit links later.

---

## 2. Current FastCheckin Backend Facts

The inspected repo is a Phoenix app named `:fastcheck` with module root `FastCheck`. It already has Cachex, Redix, Oban, Req, Phoenix, Ecto, telemetry, Sentry, JWT/mobile dependencies, and security tooling.

Relevant runtime components already exist:

```text
FastCheck.TickeraCircuitBreaker
FastCheck.Events.SyncState
FastCheck.Redis.Connection
Oban
FastCheck.RateLimiterMonitor
FastCheck.Cache.EtsOwner
```

Relevant runtime routes already exist:

```text
Live scanner: /scan/:event_id
Scanner portal: /scanner/:event_id
API check-in: POST /api/v1/check-in
API bulk check-in: POST /api/v1/check-in/batch
Mobile sync down: GET /api/v1/mobile/attendees
Mobile scan upload: POST /api/v1/mobile/scans
```

Existing Attendee schema fields include:

```text
event_id
ticket_code
first_name
last_name
email
ticket_type_id
ticket_type
allowed_checkins
checkins_remaining
payment_status
custom_fields
checked_in_at
checked_out_at
last_checked_in_at
last_checked_in_date
daily_scan_count
weekly_scan_count
monthly_scan_count
is_currently_inside
last_entrance
scan_eligibility
ineligibility_reason
ineligible_since
source_last_seen_at
last_authoritative_sync_run_id
```

Current Attendee schema requires:

```text
ticket_code
event_id
```

and enforces:

```text
unique_ticket_per_event
```

Existing scan behavior treats `scan_eligibility = "not_scannable"` as scanner-denied and otherwise checks `payment_status`, duplicate status, and `checkins_remaining`.

Existing mobile sync-down only exports attendees whose `scan_eligibility` is `"active"` or `nil`, plus append-only invalidation events.

Existing Tickera reconciliation currently marks active attendees that are absent from a full authoritative Tickera snapshot as `not_scannable`, writes `AttendeeInvalidationEvent` rows, and bumps `event_sync_version`.

Implication:

```text
VS-02 must protect Sales-origin attendees before VS-09B creates any Sales-origin Attendee rows.
```

---

## 3. Non-Negotiable Boundary

Do not migrate existing Attendees to Ash.

Use existing Ecto boundary:

```text
lib/fastcheck/attendees.ex
lib/fastcheck/attendees/attendee.ex
lib/fastcheck/attendees/query.ex
lib/fastcheck/attendees/scan.ex
lib/fastcheck/attendees/reconciliation.ex
lib/fastcheck_web/controllers/mobile/sync_controller.ex
```

Add the Sales bridge in:

```text
lib/fastcheck/tickets/issuer.ex
```

Tests should live near the existing domain tests, for example:

```text
test/fastcheck/tickets/issuer_attendee_bridge_test.exs
test/fastcheck/attendees/reconciliation_sales_origin_test.exs
```

---

## 4. Scope

### In scope

```text
Create or reuse Attendee rows for paid verified Sales orders.
Use FastCheck.Tickets.Issuer as the only public issuance orchestration boundary.
Use existing Ecto Attendee schema/context.
Create exactly one Attendee per sales_order_line_id + line_item_sequence.
Generate scanner-compatible ticket_code values.
Set scanner-compatible fields: event_id, ticket_code, allowed_checkins, checkins_remaining, payment_status, scan_eligibility.
Set Sales-origin fields created by VS-02.
Use deterministic source_reference/idempotency key per issuance unit.
Prove duplicate worker retry safety.
Prove Tickera reconciliation does not invalidate Sales-origin attendees.
Invalidate attendee caches for affected event/ticket after successful creation.
Return attendee IDs for VS-09C.
```

### Out of scope

```text
No Sales TicketIssue rows.
No ticket delivery tokens.
No QR rendering.
No WhatsApp/email delivery.
No Paystack changes.
No PaymentEvent changes.
No Redis inventory mutation.
No scanner revocation/refund implementation.
No event sync aggregation implementation beyond existing cache invalidation unless explicitly required by existing sync tests.
No admin UI.
```

---

## 5. Required Pre-Implementation Checks

Before coding VS-09B, the agent must verify VS-02 has already made these true in FastCheckin:

```text
Attendee has Sales-origin fields or equivalent.
Tickera reconciliation excludes/protects Sales-origin attendees.
Tickera create_bulk/upsert cannot overwrite Sales-origin attendees.
Existing scanner tests pass.
Existing mobile sync tests pass.
Existing reconciliation tests pass.
```

Required Sales-origin fields or equivalent:

```text
source                  # expected: "tickera" | "fastcheck_sales"
source_reference        # deterministic non-PII reference
sales_order_id
sales_order_line_id
line_item_sequence
sales_ticket_issue_id   # nil until VS-09C
```

If those fields or their equivalents are missing:

```text
STOP and report BLOCKED: VS-02 Attendee Origin Protection has not been implemented.
```

Do not fold VS-02 into VS-09B unless the assigned issue explicitly says to repair a missing dependency.

---

## 6. Attendee Creation Contract

For each paid order line:

```text
OrderLine.quantity = N
```

Create or reuse these issuance units:

```text
sales_order_line_id + line_item_sequence = 1..N
```

Each unit creates/reuses exactly one Attendee.

Required attributes for a Sales-created Attendee:

```text
event_id: order.event_id
ticket_code: secure scanner-compatible code from VS-08
first_name / last_name / email: buyer or attendee capture values, with PII logging restrictions
ticket_type_id: existing-compatible value if required, otherwise nil
ticket_type: order_line.ticket_type or offer_name_snapshot
allowed_checkins: 1 unless offer explicitly allows more
checkins_remaining: allowed_checkins
payment_status: "completed"
scan_eligibility: "active"
source: "fastcheck_sales"
source_reference: deterministic source ref
sales_order_id: order.id
sales_order_line_id: order_line.id
line_item_sequence: sequence
sales_ticket_issue_id: nil
custom_fields: minimal non-sensitive Sales metadata if needed for admin/search
```

Do not put raw payment payloads, Paystack refs, QR tokens, delivery tokens, phone numbers, or authorization URLs into `custom_fields`.

---

## 7. Source Reference Model

Use a deterministic non-PII source reference.

Recommended format:

```text
sales_order_line:{sales_order_line_id}:seq:{line_item_sequence}
```

Rules:

```text
Must not include buyer email/phone.
Must not include raw Paystack reference unless explicitly approved.
Must be unique for each issuance unit.
Must be safe for logs.
Must support idempotent retry forever.
```

Required DB protection:

```text
unique(source, source_reference) where source = 'fastcheck_sales'
```

or an equivalent partial unique index:

```text
unique(sales_order_line_id, line_item_sequence) where source = 'fastcheck_sales'
```

Keep the existing `unique_ticket_per_event` behavior for scanner lookup compatibility.

---

## 8. Tickera Reconciliation Protection

Current `FastCheck.Attendees.Reconciliation` marks active attendees absent from a full Tickera import as `not_scannable`.

VS-09B depends on VS-02 changing that behavior so Sales-origin attendees are excluded from Tickera absence invalidation.

Required behavior after VS-02 and before VS-09B acceptance:

```text
source='fastcheck_sales' attendees are not marked not_scannable just because they are absent from Tickera.
source='fastcheck_sales' attendees are not overwritten by Tickera create_bulk/upsert.
source='tickera' or nil attendees keep existing Tickera reconciliation behavior.
AttendeeInvalidationEvent remains the append-only scanner sync tombstone for real invalidations.
event_sync_version continues to bump after authoritative reconciliation.
```

VS-09B tests must include Sales-origin reconciliation regression tests even if VS-02 implemented the protection earlier.

---

## 9. Scanner and Mobile Compatibility

Existing scanner/mobile path expects:

```text
event_id + ticket_code lookup
scan_eligibility active or nil for sync-down/scannability
scan_eligibility not_scannable for scanner denial
payment_status accepted by scan logic
allowed_checkins/checkins_remaining for duplicate/exhaustion logic
```

VS-09B must not change scanner rules except to ensure Sales-created attendees fit the existing rules.

Required cache behavior:

```text
After Attendee creation/reuse, invalidate attendee id cache if relevant.
Invalidate event attendee list cache for the event.
Clear/refresh ETS attendee cache for created ticket codes if existing helper exists.
Do not introduce polling.
Do not broadcast ticket-issued/delivery events yet.
```

Mobile sync note:

```text
New Sales-created attendees must be visible to mobile sync if scan_eligibility is active.
VS-10 owns sync version aggregation; VS-09B may only call existing bump/invalidation if current mobile sync tests prove newly created attendees are otherwise invisible.
```

---

## 10. Transaction and Concurrency Rules

Use the VS-09A selected model.

Preferred if Sales Ash tables and Attendees use `FastCheck.Repo`:

```text
Repo.transaction / Ecto.Multi
  lock/load Sales.Order
  verify paid_verified or fulfillment_queued
  load OrderLine rows
  expand quantity into issuance units
  create_or_reuse Attendee per unit by source/source_reference
  invalidate affected caches
  return attendee IDs
commit
```

If Ash and Attendees cannot be safely handled in one transaction:

```text
Use the VS-09A saga/recovery model.
Persist progress checkpoints.
Retry must reuse existing attendees.
Manual review on unrecoverable conflicts.
```

Concurrency guards:

```text
Use order-level lock/advisory lock.
Use DB unique constraints for issuance units.
Do not rely on Oban uniqueness alone.
Use insert-or-get behavior for source/source_reference conflicts.
Treat conflicting owner data as manual_review, not overwrite.
```

---

## 11. RED/GREEN Test Plan

### RED tests first

```text
RED: paid_verified order with quantity 3 creates exactly 3 Attendees.
RED: each Attendee has event_id, ticket_code, payment_status="completed", scan_eligibility="active", allowed_checkins=1, checkins_remaining=1.
RED: each Attendee has source="fastcheck_sales" and deterministic source_reference.
RED: duplicate issue_order call reuses the same Attendees.
RED: concurrent issue_order calls do not create duplicates.
RED: partial failure after first Attendee can be retried and completes missing units.
RED: unpaid/cancelled/expired/refunded orders cannot create Attendees.
RED: Sales-created Attendee missing from Tickera full snapshot remains active/scannable.
RED: Tickera-origin Attendee missing from Tickera full snapshot is still marked not_scannable.
RED: Tickera create_bulk/upsert cannot overwrite Sales-origin attendees.
RED: mobile sync-down includes active Sales-created attendees.
RED: scanner check-in accepts an active Sales-created attendee with completed payment_status.
RED: scanner check-in rejects a Sales-created attendee if scan_eligibility is not_scannable.
RED: VS-09B creates no TicketIssue rows.
RED: no Paystack, WhatsApp, Redis inventory, DeliveryAttempt, or scanner revocation code is touched.
RED: logs do not include buyer email/phone, raw provider payloads, QR tokens, delivery tokens, or full ticket codes.
```

### GREEN targets

```text
GREEN: FastCheck.Tickets.Issuer creates/reuses attendees through existing Ecto code.
GREEN: DB uniqueness enforces source/source_reference idempotency.
GREEN: existing Attendee fixture/test style is reused.
GREEN: existing reconciliation tests still pass.
GREEN: existing scanner/mobile sync tests still pass.
GREEN: VS-09C can consume attendee IDs for TicketIssue audit linking.
```

---

## 12. File-Level Guidance

### Add

```text
lib/fastcheck/tickets/issuer.ex
test/fastcheck/tickets/issuer_attendee_bridge_test.exs
```

### Verify / possibly extend only if VS-02 dependency is already in scope

```text
lib/fastcheck/attendees/attendee.ex
lib/fastcheck/attendees.ex
lib/fastcheck/attendees/reconciliation.ex
priv/repo/migrations/*attendee*source*sales*.exs
test/fastcheck/attendees/reconciliation_sales_origin_test.exs
```

### Do not modify unless tests prove unavoidable

```text
lib/fastcheck/attendees/scan.ex
lib/fastcheck_web/controllers/mobile/sync_controller.ex
lib/fastcheck_web/router.ex
```

---

## 13. Performance and Scaling Review

### Data layer ownership

```text
Hot scanner lookup: existing ETS/Cachex + DB lookup by event_id/ticket_code.
Warm event attendee lists: existing attendee event cache, 5m TTL in current cache module.
Cold durable truth: Postgres attendees table and Sales tables.
Redis inventory: no mutation in this slice.
```

### Scaling rules

```text
Do not scan all attendees while issuing.
Lookup by indexed source/source_reference or sales_order_line_id + line_item_sequence.
Keep transaction small.
No external HTTP inside transaction.
No QR rendering or delivery inside transaction.
Invalidate only affected attendee/event caches.
Do not create large in-memory lists beyond one order's lines.
```

### Required indexes

```text
attendees unique(source, source_reference) where source='fastcheck_sales'
attendees index(event_id, source)
attendees index(source, source_reference)
attendees index(sales_order_id) if field exists
attendees index(sales_order_line_id, line_item_sequence) if fields exist
retain existing unique_ticket_per_event
```

---

## 14. Security Rules

```text
Never log buyer_phone, buyer_email, access_code, authorization_url, raw provider payload, qr_token, delivery_token, or full ticket_code.
Do not put PII into source_reference.
Do not expose Attendee internal IDs as customer-facing ticket references.
Do not store plaintext delivery tokens in Attendee.
Use correlation_id/source_reference/order public reference in logs.
```

---

## 15. Failure Modes

| Failure | Required behavior |
|---|---|
| Duplicate worker runs | Reuse existing Attendees by source/source_reference. |
| Worker crashes after some Attendees | Retry reuses created rows and creates missing rows. |
| Ticket code collision in same event | Regenerate if safe before insert; otherwise manual_review. |
| source_reference exists but belongs to different order unit | manual_review, no overwrite. |
| Tickera tries to invalidate Sales attendee | Must remain active; regression test required. |
| Tickera upsert collides with Sales ticket_code | Do not overwrite Sales attendee; manual-review/log conflict. |
| Order not verified paid | Return invalid state; create nothing. |
| Existing scanner rejects Sales attendee | Fix bridge attrs, not scanner rules, unless minimal compatibility is unavoidable. |

---

## 16. TOON Coding-Agent Prompt

| Field | Content |
|---|---|
| Task | Implement VS-09B Attendee Creation Bridge in `JCSchoeman96/FastCheckin`. |
| Objective | Create scanner-compatible Ecto Attendee rows from verified Sales orders through `FastCheck.Tickets.Issuer`, while preserving Tickera reconciliation safety and making retries idempotent. |
| Output | `lib/fastcheck/tickets/issuer.ex`; focused tests under `test/fastcheck/tickets/`; reconciliation/mobile/scanner regression tests as needed; final report listing Attendee fields, indexes, cache invalidations, and deferred VS-09C work. |
| Note | Use existing `FastCheck.Attendees.Attendee` and `FastCheck.Attendees` boundary. Existing schema currently uses `event_id`, `ticket_code`, `payment_status`, `allowed_checkins`, `checkins_remaining`, and `scan_eligibility`. VS-02 must have added/protected `source`, `source_reference`, and Sales lineage fields before this slice. If missing, stop as BLOCKED rather than mixing VS-02 into VS-09B. Required DB protection: partial unique index for Sales source refs. Create one Attendee per `sales_order_line_id + line_item_sequence`. Use `payment_status="completed"`, `scan_eligibility="active"`, `allowed_checkins=1`, `checkins_remaining=1` unless offer rules say otherwise. Invalidate affected attendee/event caches. Do not create `TicketIssue`, DeliveryAttempt, QR, WhatsApp/email delivery, Paystack changes, Redis inventory mutation, event sync aggregation, or scanner revocation. Tests must prove duplicate-worker safety, partial retry recovery, Tickera reconciliation protection, mobile sync visibility, scanner acceptance, and log redaction. |
| Success | A verified order creates/reuses the exact expected Attendee rows once, Sales-origin attendees survive Tickera sync, scanner/mobile paths remain compatible, and VS-09C can link TicketIssue rows using returned attendee IDs. |

---

## 17. Copy-Paste Prompt for Coding Agent

```text
You are implementing FastCheck Sales VS-09B — Attendee Creation Bridge in JCSchoeman96/FastCheckin.

First verify dependencies:
- VS-02 must have added/protected Sales-origin attendee fields.
- VS-09A must define the issuer transaction/saga model.
- VS-08 must provide scanner-compatible ticket code generation.
- VS-07C must produce verified paid order state.

If Attendee source/source_reference/Sales lineage fields are missing, stop and report BLOCKED: VS-02 is not implemented.

Implement only the attendee bridge:
- Add/use FastCheck.Tickets.Issuer.issue_order(order_id, opts \ []).
- Load and lock the verified paid Sales order.
- Allow only paid_verified or fulfillment_queued according to VS-09A.
- Expand each OrderLine quantity into sales_order_line_id + line_item_sequence units.
- Create or reuse one FastCheck.Attendees.Attendee per unit.
- Required scanner-compatible fields: event_id, ticket_code, payment_status="completed", allowed_checkins=1, checkins_remaining=1, scan_eligibility="active".
- Required Sales-origin fields: source="fastcheck_sales", source_reference, sales_order_id, sales_order_line_id, line_item_sequence, sales_ticket_issue_id=nil.
- Use DB unique constraint for idempotency.
- Invalidate affected attendee caches.
- Return attendee IDs for VS-09C.

Do not create TicketIssue rows, do not mark order ticket_issued, do not send tickets, do not call Paystack, do not mutate Redis inventory, do not touch WhatsApp/Meta, and do not implement revocation.

Write RED tests first for duplicate calls, concurrent calls, partial retry, Tickera reconciliation protection, mobile sync visibility, scanner acceptance, invalid order states, no TicketIssue rows, and log redaction.
```

---

## 18. Human Review Checklist

```text
[ ] Pack uses FastCheckin, not vg_app.
[ ] Existing Attendee schema fields reviewed.
[ ] VS-02 source/source_reference protection exists before bridge implementation.
[ ] Existing Tickera reconciliation protection verified.
[ ] Existing scanner acceptance path remains stable.
[ ] Mobile sync-down still exports active Sales attendees.
[ ] One Attendee per sales_order_line_id + line_item_sequence.
[ ] DB unique constraint protects Sales issuance units.
[ ] Duplicate/retry/concurrency tests pass.
[ ] Partial failure retry tests pass.
[ ] Existing reconciliation tests pass.
[ ] Existing scanner/mobile tests pass.
[ ] No TicketIssue rows created.
[ ] No Paystack/WhatsApp/Redis/delivery behavior added.
[ ] Cache invalidation is scoped and documented.
[ ] Logs are PII/token safe.
```

---

## 19. Next Slice

```text
VS-09C — TicketIssue Audit Linking
```
