# FastCheck Sales Feature Planning Pack — VS-02 Attendee Origin Protection

**Pack ID:** `0012_VS-02_attendee-origin-protection`  
**Repository path:** `docs/fastcheck_sales/feature_packs/0012_VS-02_attendee-origin-protection`  
**Slice:** `VS-02`  
**Slice name:** Attendee Origin Protection  
**Version:** `v1.0`  
**Date:** 2026-06-12  
**Status:** Ready for implementation only after VS-01D, VS-01F, VS-01G, and all planning gates are accepted  
**Primary area:** Existing Attendees / Tickera Sync / Scanner Visibility / Ecto / Tests  
**Depends on:** VS-00A, VS-00B, VS-00C, VS-00D, VS-01A, VS-01B, VS-01C, VS-01D, VS-01F, VS-01G  
**Blocks:** VS-09A, VS-09B, VS-09C, VS-09D, VS-10, VS-15A, VS-15B  
**Source docs:**

```text
docs/fastcheck_sales/SOURCE_DOCS/FastCheck_Sales_Ash_Atlas_Planning_Pack_v0.2.3_HARDENED.md
docs/fastcheck_sales/SOURCE_DOCS/FastCheck_Sales_Vertical_Slice_Roadmap_v1.1.3_HARDENED.md
```

---

## 0.1 Repo Alignment Patch — Existing Scanner Eligibility Authority

This pack has been aligned to the current FastCheckin repository. The existing Attendee scanner-truth model already uses:

```text
scan_eligibility
ineligibility_reason
ineligible_since
source_last_seen_at
last_authoritative_sync_run_id
```

Therefore this slice must **not** introduce a duplicate `attendees.scan_eligibility` field as scanner authority. Any Sales-side `TicketIssue.scan_eligibility` remains a Sales audit/snapshot concept only and must not replace the existing Attendee scanner eligibility fields.

Revocation/refund/cancellation for Sales-origin attendees must map into the existing Attendee path as:

```text
scan_eligibility = active         # scanner-acceptable, subject to existing scan rules
scan_eligibility = not_scannable  # scanner-denied
ineligibility_reason = revoked | refunded | cancelled | blocked | manual_review | equivalent repo-safe code
ineligible_since = UTC timestamp when attendee became non-scannable
```

## 1. Purpose

This pack protects FastCheck-sales-created attendees from being damaged by existing Tickera sync or reconciliation behavior.

The Sales core will eventually issue tickets by creating existing FastCheck Attendee rows. Those rows must remain scanner-compatible, but they must not be treated as Tickera-owned records. This slice creates or verifies the attendee-origin model that lets the existing system distinguish:

```text
Tickera-created attendees
FastCheck Sales-created attendees
manual/admin-created attendees
imported/test attendees
```

This slice is a legacy-boundary protection slice. It is not an Ash resource slice. It may touch existing Ecto Attendee schema/context and Tickera reconciliation logic, but it must not move Attendees into Ash and must not rewrite the scanner hot path.

Strategic framing remains:

```text
FastCheck Sales is multi-channel, but WhatsApp is first.

Primary production customer channel:
  WhatsApp via Meta Cloud API

Secondary supported Sales paths:
  admin-assisted sales
  web checkout sales
  internal pilot sales

All channels eventually issue scanner-compatible attendees through one approved issuance bridge.
This slice makes those future Sales-created attendees safe from Tickera reconciliation.
```

---

## 2. Ultimate Outcome

After VS-02 is complete:

```text
Existing Attendee records can carry a durable origin/source marker.
FastCheck Sales-created attendees can be identified without guessing.
Tickera reconciliation does not delete, overwrite, or invalidate Sales-created attendees.
Refunded/revoked Sales-created attendees have a scanner-visible non-acceptable state path defined.
Future VS-09 ticket issuance can safely create attendee rows with Sales origin metadata.
Future VS-15 revocation can safely mark Sales tickets as non-scannable through the existing attendee/scanner model.
Existing Tickera attendees continue to sync normally.
Existing scanner hot path remains stable unless a tiny, reviewed eligibility helper change is required.
Tests prove Sales-origin attendees survive Tickera reconciliation.
```

The goal is not to issue tickets yet. The goal is to protect the future issuance path before it exists.

---

## 3. Scope

### In scope

```text
Inspect existing Attendee schema, context, scanner eligibility rules, Tickera sync, and reconciliation modules.
Add or verify attendee origin/source fields.
Add or verify Sales-origin reference fields.
Add or verify scanner visibility/revocation fields if missing.
Add or verify indexes needed for origin lookup, Sales linkage, and scanner visibility.
Patch Tickera reconciliation so it only owns Tickera-origin attendees.
Patch destructive sync paths to skip or preserve FastCheck Sales-origin attendees.
Add tests proving Sales-origin attendees are not deleted or overwritten by Tickera sync.
Add tests proving Tickera-origin attendees still reconcile normally.
Add tests proving scanner eligibility can distinguish active vs revoked/refunded Sales-origin attendees.
Document confirmed existing file paths and field names.
```

### Out of scope

```text
No Ash migration of existing Attendees.
No new Ash resource for Attendee.
No ticket issuance orchestration.
No creation of Sales TicketIssue records.
No Paystack integration.
No Meta/WhatsApp integration.
No QR generation.
No delivery-token generation.
No customer ticket page.
No admin manual-review UI.
No event sync version aggregator implementation.
No broad scanner hot-path rewrite.
No Android/mobile API rewrite.
No Redis inventory implementation.
```

---

## 4. Required Pre-Implementation Decisions

The coding agent must read and follow accepted outputs from:

```text
VS-00A State Machine and Failure Policy Finalization
VS-00B Security, PII, and Token Policy Finalization
VS-00C Inventory Recovery and Reconciliation Contract
VS-00D MVP Purchase Entry-Point and Launch Scope Decision
VS-01D Ticket and Delivery Resource Skeletons
VS-01F Ash Policy Foundation
VS-01G Index and Migration Verification
```

### Required discovery step

Before editing code, the agent must locate and document the existing project paths for:

```text
Attendee Ecto schema
Attendee context/service module
Tickera sync module(s)
Tickera reconciliation module(s)
scanner eligibility/check-in logic
mobile sync version logic or event sync bump logic
existing attendee tests
existing scanner/reconciliation tests
```

The slice documentation must record the confirmed paths. Do not assume these names if the repository differs.

### Origin model decision

Use existing naming if the codebase already has an origin/source concept. If no suitable fields exist, implement the minimum explicit model below.

Recommended fields or equivalent on the existing Attendee table:

```text
source                  # string/enum: tickera, fastcheck_sales, manual, import, test
source_reference        # external/source-specific reference
sales_order_id          # nullable reference to Sales order, no hard dependency in this slice if not safe
sales_ticket_issue_id   # nullable reference to Sales ticket issue, unique when not null
revoked_at              # nullable timestamp
revocation_reason       # nullable string/text
scan_eligibility         # existing FastCheck scanner truth: active or not_scannable
ineligibility_reason     # existing reason/code when not scannable
ineligible_since         # existing timestamp when attendee became not scannable
```

Naming may be adapted to existing conventions, but the semantics must be preserved.

### Scanner eligibility model

Minimum Attendee scanner eligibility values must follow the existing FastCheckin model:

```text
active
not_scannable
```

Detailed denial reasons belong in `ineligibility_reason`, for example:

```text
revoked
refunded
cancelled
blocked
manual_review
```

Only `scan_eligibility = active` should remain scanner-acceptable for Sales-origin attendees unless existing scanner policy adds stricter rules.

### Event sync note

This slice must not implement the full event sync aggregator from VS-10. It must document what future VS-10 must update after attendee origin/revocation changes.

---

## 5. Ash Domain and Resource Details

### Ash domain involved

```text
FastCheck.Sales
```

### Ash resources referenced but not modified

```text
FastCheck.Sales.Order
FastCheck.Sales.TicketIssue
FastCheck.Sales.StateTransition
```

This slice does not create or change Ash resources unless a tiny documentation-only reference is needed.

### Existing Ecto boundary

Attendees remain in the existing Ecto context/schema. Do not migrate Attendees into Ash.

Expected boundary:

```text
FastCheck.Tickets.Issuer        # future VS-09 owner of actual attendee creation
Existing Attendees context      # owns Attendee row creation/update rules
Existing Tickera sync/reconcile # owns Tickera-origin rows only
Existing scanner path           # reads scanner-visible attendee validity
```

### Future relationship contract

Future VS-09 issuance must be able to create an attendee row with:

```text
source = fastcheck_sales
source_reference = stable Sales issuance reference
sales_order_id = Sales order id or reference if accepted
sales_ticket_issue_id = Sales TicketIssue id or reference if accepted
scan_eligibility = active
```

Future VS-15 revocation must be able to update:

```text
scan_eligibility = not_scannable
ineligibility_reason = revoked/refunded/cancelled/audit-safe code
ineligible_since = current UTC timestamp
revoked_at = current UTC timestamp if retained as Sales-specific revocation metadata
revocation_reason = audit-safe reason if retained as Sales-specific revocation metadata
```

---

## 6. Required Existing File Areas

The agent must discover actual paths. These likely areas must be inspected:

```text
lib/fastcheck/attendees.ex
lib/fastcheck/attendees/attendee.ex
lib/fastcheck/attendees/reconciliation.ex
lib/fastcheck/events/sync.ex
lib/fastcheck/events/tickera_sync.ex
lib/fastcheck/attendees/scan.ex
lib/fastcheck_web/controllers/api/*scanner*
lib/fastcheck_web/controllers/*scan*
priv/repo/migrations/*attendee*.exs
test/fastcheck/attendees/*test.exs
test/fastcheck/events/*sync*test.exs
test/fastcheck/*scanner*test.exs
```

If the real repository uses different paths, use the real paths and document them in:

```text
docs/fastcheck_sales/slices/VS-02_ATTENDEE_ORIGIN_PROTECTION.md
```

---

## 7. Required Data Contract

### Minimum origin fields

If missing, add fields or equivalent to the existing Attendee schema/table:

```text
source
source_reference
sales_order_id
sales_ticket_issue_id
scan_eligibility
ineligibility_reason
ineligible_since
source_last_seen_at
last_authoritative_sync_run_id
revoked_at
revocation_reason
```

### Field semantics

```text
source:
  durable origin marker; never infer origin from null/non-null external IDs alone.

source_reference:
  provider/source-specific reference. For Tickera this may be order/ticket/user id. For Sales this should be a stable Sales issuance reference.

sales_order_id:
  nullable Sales link for future support/reporting; may be UUID/string/integer matching accepted Sales ID type.

sales_ticket_issue_id:
  nullable Sales TicketIssue link; must be unique when not null if stored directly.

scan_eligibility:
  existing FastCheck attendee scanner-truth field. Use `active` for scanner-acceptable and `not_scannable` for denied attendees. Do not add a duplicate `attendees.scanner_status` field unless an explicit future migration decision replaces the current model.

ineligibility_reason:
  existing reason/code field used when `scan_eligibility = not_scannable`; may contain revoked/refunded/cancelled/blocked/manual_review or equivalent repo-safe values.

ineligible_since:
  existing timestamp field recording when the attendee became not scannable.

revoked_at:
  timestamp for revocation/refund/cancellation scanner invalidation.

revocation_reason:
  audit-safe reason. Do not store raw provider payloads or sensitive customer notes here.
```

### Required indexes

Use actual attendee table name. Recommended indexes:

```text
index(attendees, [:source])
index(attendees, [:source, :source_reference])
unique_index(attendees, [:sales_ticket_issue_id], where: "sales_ticket_issue_id IS NOT NULL")
index(attendees, [:sales_order_id], where: "sales_order_id IS NOT NULL")
index(attendees, [:event_id, :scan_eligibility])
index(attendees, [:event_id, :source])
```

If the existing table is large, prefer concurrent index strategy if the project’s migration/deploy process supports it. Do not add broad indexes over raw notes or PII fields.

---

## 8. Tickera Reconciliation Rules

Tickera sync/reconciliation must treat origin as ownership.

### Correct behavior

```text
Tickera sync may create/update/delete only Tickera-origin attendees.
Tickera reconciliation must skip fastcheck_sales-origin attendees.
Tickera reconciliation must not overwrite source, scan_eligibility, ineligibility_reason, ineligible_since, source_last_seen_at, last_authoritative_sync_run_id, revoked_at, sales_order_id, or sales_ticket_issue_id for fastcheck_sales-origin attendees.
If a Sales-origin attendee has no matching Tickera record, that is expected and must not be treated as orphan cleanup.
```

### Wrong behavior

```text
Delete attendee because no Tickera source row exists.
Overwrite Sales-created attendee details with Tickera payload.
Clear sales_order_id or sales_ticket_issue_id during reconciliation.
Set source back to tickera because event/ticket type matches.
Treat null Tickera ID as proof that the attendee is invalid.
```

### Legacy records

If legacy attendees do not have `source`, migration/backfill must choose a safe default.

Recommended default:

```text
source = tickera
```

Only if legacy records are known to all be Tickera-origin. If not, create a conservative `legacy_unknown` value and document remediation.

Do not silently mark unknown records as Sales-origin.

---

## 9. Scanner Visibility Rules

This slice must not rewrite the scanner hot path, but it must establish scanner-safe fields and tests.

Minimum rule for Sales-origin attendees:

```text
source = fastcheck_sales AND scan_eligibility = active -> potentially scannable, subject to existing scan rules
source = fastcheck_sales AND scan_eligibility = not_scannable -> not scannable
ineligibility_reason IN revoked/refunded/cancelled/blocked/manual_review -> not scannable
revoked_at is not null -> not scannable if retained as separate Sales revocation metadata
```

If the current scanner logic uses existing fields like `checked_in`, `cancelled`, `status`, or `deleted_at`, the agent must integrate the new status model minimally and document the mapping.

Avoid changing scanner behavior for existing Tickera-origin active attendees.

---

## 10. Security and PII Rules

Apply VS-00B security policy:

```text
Do not log buyer phone, email, raw provider payloads, delivery tokens, QR tokens, or raw WhatsApp payloads.
Do not add indexes over PII fields unless existing query paths already require them and security policy permits it.
Do not expose Sales-origin fields in public APIs unless existing API contract requires it.
Do not expose internal sales_order_id or sales_ticket_issue_id to customer-facing responses by default.
```

Admin/operator display rules are not implemented here, but fields must be safe for future support views.

---

## 11. Performance and Scaling Review

### Data layer

```text
Attendee origin markers: Postgres cold/durable data
Scanner eligibility: existing Postgres durable `scan_eligibility` / `ineligibility_reason` / `ineligible_since` path, later cached/synced to mobile scanner path as existing system requires
Tickera reconciliation filters: Postgres indexed query paths
Event sync bump: future VS-10; do not implement here unless existing system requires a minimal bump to keep tests correct
```

### Required performance checks

```text
Tickera reconciliation must filter by source/origin using indexes.
Sales-origin lookup by sales_ticket_issue_id must be indexed.
Event scanner-eligibility lookup must use the existing indexed event_id + scan_eligibility path or add it if missing.
No large attendee table scan should be introduced in peak event/scanner paths.
No Redis representation is required in this slice.
No PubSub broadcast is required in this slice unless existing attendee updates already broadcast.
```

### Scale warning

If attendee tables are already large, migration/index creation must be reviewed for lock impact before production deployment.

---

## 12. RED / GREEN Test Plan

This slice must be test-first where possible. Write RED tests that fail before implementation, then make them GREEN with minimal code.

### RED tests that must fail before implementation

```text
Creating a Sales-origin attendee without an origin/source marker is rejected or impossible through the approved helper.
Tickera reconciliation deletes or marks invalid a Sales-origin attendee with no Tickera source row.
Tickera reconciliation overwrites Sales-origin fields from a Tickera payload.
Duplicate attendees can be linked to the same sales_ticket_issue_id.
A revoked/refunded Sales-origin attendee remains scanner-acceptable.
A Sales-origin attendee lookup by sales_ticket_issue_id has no unique/index protection.
Existing Tickera attendee reconciliation behavior is not covered by regression tests.
```

### GREEN tests required after implementation

```text
Sales-origin attendee has durable source = fastcheck_sales or equivalent.
Tickera-origin attendee still syncs/reconciles normally.
Sales-origin attendee survives Tickera reconciliation when absent from Tickera feed.
Sales-origin attendee Sales linkage fields are not overwritten by Tickera reconciliation.
Duplicate non-null sales_ticket_issue_id is rejected by the DB.
Revoked/refunded/cancelled Sales-origin attendee is scanner-non-acceptable.
Active Sales-origin attendee remains eligible subject to existing scanner rules.
Legacy/backfilled attendees receive safe source values.
Indexes/constraints exist for source, sales_ticket_issue_id, sales_order_id, event_id + scan_eligibility.
No Ash Attendee resource is created.
No Paystack/Meta/Redis/ticket issuance code is added.
```

### Suggested test files

Use actual project conventions. Likely test locations:

```text
test/fastcheck/attendees/attendee_origin_test.exs
test/fastcheck/attendees/tickera_reconciliation_origin_test.exs
test/fastcheck/attendees/scan_eligibility_origin_test.exs
test/fastcheck/attendees/attendee_origin_migration_test.exs
```

If existing test folders differ, use the existing structure and document the chosen paths.

---

## 13. Acceptance Criteria

This slice is accepted only when:

```text
Confirmed existing Attendee, Tickera sync/reconciliation, scanner eligibility, and mobile sync file paths are documented.
Attendee origin/source fields exist or equivalent semantics are documented.
FastCheck Sales-origin attendees can be distinguished from Tickera-origin attendees.
Tickera reconciliation skips/protects Sales-origin attendees.
Tickera-origin attendees still reconcile normally.
Sales-origin attendee linkage fields exist or future VS-09 linkage strategy is explicitly documented.
Revocation/scanner eligibility fields use existing `scan_eligibility`, `ineligibility_reason`, and `ineligible_since` fields, or an equivalent scanner-safe model is documented.
DB indexes/constraints support source lookup, Sales linkage, and scanner-eligibility query paths.
RED/GREEN tests prove origin protection and scanner visibility behavior.
No Ash migration of existing Attendees occurs.
No ticket issuance logic is implemented.
No scanner hot-path rewrite occurs.
No Paystack, Meta, Redis, WhatsApp, QR, token-delivery, admin UI, or mobile API behavior is added.
```

---

## 14. Explicit Non-Goals

Do not let the coding agent expand this slice into:

```text
full ticket issuance
admin refund UI
scanner redesign
mobile API versioning implementation
event sync aggregator
Paystack verification
WhatsApp flow
QR generation
delivery-token system
Sales dashboard
manual review screens
```

This slice is protective plumbing only. Keep it boring and correct.

---

## 15. TOON Coding-Agent Prompt

| Field | Content |
|---|---|
| Task | Implement VS-02 Attendee Origin Protection for existing FastCheck Attendees and Tickera reconciliation. |
| Objective | Ensure future FastCheck Sales-created attendees can be safely distinguished from Tickera-created attendees, protected from Tickera reconciliation, and marked scanner-non-acceptable when revoked/refunded/cancelled. This protects the future Sales ticket issuance bridge before VS-09 creates real Sales attendees. |
| Output | Confirmed path documentation at `docs/fastcheck_sales/slices/VS-02_ATTENDEE_ORIGIN_PROTECTION.md`; existing Attendee schema/context updates if required; migration(s) for origin/linkage/scanner-eligibility fields if missing; Tickera reconciliation changes that skip/protect Sales-origin attendees; scanner eligibility helper/minimal status mapping if required; RED/GREEN tests for origin protection, reconciliation safety, uniqueness/indexes, and scanner-eligibility behavior. |
| Note | Use Ash 3.x only for the Sales domain; do not migrate Attendees to Ash. Do not implement ticket issuance, Paystack, Meta/WhatsApp, Redis, QR, delivery tokens, admin UI, or mobile API behavior. First discover and document existing Attendee, Tickera sync/reconciliation, scanner, and mobile sync paths. Required fields or equivalents: `source`, `source_reference`, `sales_order_id`, `sales_ticket_issue_id`, `scan_eligibility`, `revoked_at`, `revocation_reason`. Required indexes: source lookup, Sales linkage, `event_id + scan_eligibility`, and partial unique non-null `sales_ticket_issue_id` if stored directly. Tickera reconciliation may only own Tickera-origin attendees. Sales-origin attendees must not be deleted, overwritten, or invalidated because they are absent from Tickera. Revoked/refunded/cancelled Sales-origin attendees must be scanner-non-acceptable. Keep changes minimal and scalable; avoid large table scans and broad scanner rewrites. |

---

## 16. Copy-Paste Agent Prompt

```text
You are implementing FastCheck Sales VS-02 — Attendee Origin Protection.

Use the accepted docs:
- docs/fastcheck_sales/SOURCE_DOCS/FastCheck_Sales_Ash_Atlas_Planning_Pack_v0.2.3_HARDENED.md
- docs/fastcheck_sales/SOURCE_DOCS/FastCheck_Sales_Vertical_Slice_Roadmap_v1.1.3_HARDENED.md
- VS-00A, VS-00B, VS-00C, VS-00D outputs
- VS-01B through VS-01G outputs

Goal:
Protect future FastCheck Sales-created attendees from Tickera reconciliation while keeping existing Tickera attendees and scanner behavior stable.

First discover and document actual repo paths for:
- existing Attendee schema/context
- Tickera sync/reconciliation modules
- scanner eligibility/check-in logic
- mobile/event sync version logic
- relevant tests

Write the path notes to:
docs/fastcheck_sales/slices/VS-02_ATTENDEE_ORIGIN_PROTECTION.md

Implement the minimum origin protection model using existing conventions where possible.
Required semantics:
- Attendees have a durable origin/source marker.
- FastCheck Sales-created attendees can be marked with source = fastcheck_sales or equivalent.
- Tickera reconciliation may only delete/overwrite Tickera-origin attendees.
- Sales-origin attendees must survive Tickera reconciliation even if absent from Tickera feed.
- Sales-origin linkage fields must be preserved by Tickera reconciliation.
- Duplicate non-null sales_ticket_issue_id must be rejected if that field is used.
- Revoked/refunded/cancelled Sales-origin attendees must be scanner-non-acceptable.

Recommended fields or equivalents:
- source
- source_reference
- sales_order_id
- sales_ticket_issue_id
- scan_eligibility
- revoked_at
- revocation_reason

Recommended indexes:
- source
- source + source_reference
- unique sales_ticket_issue_id where not null
- sales_order_id where not null
- event_id + scan_eligibility
- event_id + source

RED/GREEN tests required:
- Sales-origin attendee survives Tickera reconciliation.
- Tickera-origin attendee still reconciles normally.
- Tickera reconciliation does not overwrite Sales linkage/scanner eligibility fields.
- Duplicate sales_ticket_issue_id is rejected if used.
- Revoked/refunded/cancelled Sales-origin attendee is scanner-non-acceptable.
- No Ash Attendee resource is created.
- No Paystack/Meta/Redis/ticket issuance/admin UI/mobile API behavior is added.

Hard boundaries:
- Do not migrate Attendees into Ash.
- Do not implement ticket issuance.
- Do not implement Paystack, Meta/WhatsApp, Redis, QR, delivery tokens, admin UI, or event sync aggregator.
- Do not rewrite the scanner hot path; only make a minimal helper/status integration if needed and test it.
- Do not log PII or raw provider/customer payloads.

Run relevant formatting, compile, migrations, and tests. Keep the implementation minimal, explicit, and safe under future VS-09 ticket issuance.
```

---

## 17. Human Review Checklist

Reviewers must confirm:

```text
The agent documented actual existing file paths before modifying behavior.
Attendee origin/source semantics are explicit and durable.
Sales-origin attendees are protected from Tickera reconciliation.
Tickera-origin attendees still sync/reconcile normally.
Sales linkage fields are preserved and indexed.
Revoked/refunded/cancelled Sales-origin attendees are scanner-non-acceptable.
Scanner hot path was not broadly rewritten.
No Attendee Ash resource was created.
No ticket issuance behavior slipped into this slice.
No Paystack/Meta/Redis/WhatsApp/QR/token/admin UI/mobile API behavior was added.
RED/GREEN tests exist and prove the critical safety behavior.
Migration/index lock risk was considered if the attendee table is large.
```

---

## 18. Next Slice

After VS-02 is accepted, the next roadmap slice is:

```text
VS-03 — Ticket Offer Management
```

VS-09 ticket issuance must not start until VS-02 proves Sales-created attendees are safe from Tickera reconciliation.
