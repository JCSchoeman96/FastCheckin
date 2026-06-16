# VS-02 Attendee Origin Protection

## Status

Implemented as attendee-origin protection for future FastCheck Sales issuance.

## Scope

VS-02 introduces durable attendee origin/linkage metadata and prevents Tickera
authoritative sync paths from mutating `fastcheck_sales` attendees.

Tickera remains authoritative for Tickera-origin rows only.

## Paths Updated

- `priv/repo/migrations/*_add_attendee_origin_protection.exs`
- `lib/fastcheck/attendees/attendee.ex`
- `lib/fastcheck/attendees.ex`
- `lib/fastcheck/attendees/reconciliation.ex`
- `test/fastcheck/attendees/origin_protection_test.exs`
- `test/fastcheck/events/sync_test.exs`
- `test/fastcheck_web/controllers/mobile/sync_controller_test.exs`

## Data Contract Added

Added attendee metadata fields:

- `source` (non-null, default `"tickera"`)
- `source_reference`
- `sales_order_id`
- `sales_ticket_issue_id`
- `revoked_at`
- `revocation_reason`

Added DB protections:

- `attendees_source_valid` check constraint
- `attendees_sales_ticket_issue_id_uidx` partial unique index
- origin/linkage indexes for source and event-source query paths

## Ownership Rules Enforced

- Tickera import writes set `source = "tickera"` and use ticket code as default
  `source_reference`.
- Tickera conflict updates are restricted to rows where existing
  `source == "tickera"`.
- Conflicting `fastcheck_sales` rows are not overwritten by Tickera upserts.

## Reconciliation Rules Enforced

In authoritative full-sync reconciliation:

- `mark_imported_seen` applies only to Tickera-origin rows.
- `reactivate_imported` applies only to Tickera-origin rows.
- `mark_absent_not_scannable` applies only to Tickera-origin rows.
- invalidation events are emitted only for affected Tickera-origin rows.

Sales-origin attendees absent from Tickera snapshots remain unchanged.

## Scanner Authority Boundary

Scanner truth remains attendee-based and unchanged:

- `scan_eligibility`
- `ineligibility_reason`
- `ineligible_since`

`sales_ticket_issues.scanner_status` is not used for scanner acceptance in this
slice.

Reason codes continue through helpers in `FastCheck.Attendees.ReasonCodes`
instead of adding new magic strings.

## Mobile Contract Boundary

No mobile API contract changes were introduced.

`GET /api/v1/mobile/attendees` keeps the existing serialized attendee shape.
Internal VS-02 fields are intentionally not exposed:

- `source`
- `source_reference`
- `sales_order_id`
- `sales_ticket_issue_id`
- `revoked_at`
- `revocation_reason`

## Deferred Work

- VS-09 ticket issuance bridge will create/link Sales-origin attendees safely on
  this foundation.
- VS-10 sync aggregation remains responsible for broader sync orchestration
  evolution.
- VS-15 scanner-safe revocation remains responsible for revocation workflows
  that drive scanner eligibility transitions for Sales-origin attendees.
