# VS-02 Implementation Handoff

## Status

Merged.

PR: #343 — feat(attendees): protect sales-origin rows from Tickera sync  
Merge commit: `b400f65846296da77101fd09a01c77ab1035b3cb`  
Merged at: 2026-06-16T07:57:02Z  
Branch: `vs-02-attendee-origin-protection`

## What Changed

VS-02 added attendee origin/linkage/revocation metadata and enforced ownership
boundaries so Tickera sync/reconciliation can mutate Tickera-origin rows but not
`fastcheck_sales` rows. It also added regression coverage to keep scanner and
mobile contracts stable.

## Files Changed

- `.cursor/plans/vs-02-attendee-origin-protection.plan.md` — canonical VS-02
  execution contract committed with implementation.
- `priv/repo/migrations/20260616094500_add_attendee_origin_protection.exs` —
  adds attendee origin/linkage/revocation columns, `attendees_source_valid`,
  and origin/linkage indexes including partial unique
  `attendees_sales_ticket_issue_id_uidx`.
- `lib/fastcheck/attendees/attendee.ex` — schema/types/changeset ownership for
  new fields and DB-backed constraints.
- `lib/fastcheck/attendees.ex` — Tickera bulk import/upsert ownership rules,
  including conflict updates scoped to existing Tickera-owned rows.
- `lib/fastcheck/attendees/reconciliation.ex` — authoritative reconciliation
  writes and invalidation generation scoped to Tickera-origin attendees only.
- `test/fastcheck/attendees/origin_protection_test.exs` — VS-02 origin,
  ownership, reconciliation, and scanner compatibility regressions.
- `test/fastcheck/events/sync_test.exs` — full-sync regression proving absent
  `fastcheck_sales` attendees stay active and un-invalidated.
- `test/fastcheck_web/controllers/mobile/sync_controller_test.exs` — regression
  proving new internal VS-02 attendee fields are not serialized.
- `test/fastcheck/sales/core_resource_boundary_test.exs` — minimal narrowing of
  historical changed-prefix guard for now-allowed attendee/event/Tickera edits.
- `test/fastcheck/sales/vs_01e_boundary_test.exs` — same minimal narrowing.
- `test/fastcheck/sales/vs_01f_boundary_test.exs` — same minimal narrowing.
- `docs/fastcheck_sales/slices/VS-02_ATTENDEE_ORIGIN_PROTECTION.md` — slice
  implementation documentation for VS-02 runtime boundaries and deferred work.

## Contracts Now Available

- `attendees` now has durable source/linkage/revocation metadata:
  `source`, `source_reference`, `sales_order_id`, `sales_ticket_issue_id`,
  `revoked_at`, `revocation_reason`.
- `attendees_source_valid` constrains allowed source values.
- `attendees_sales_ticket_issue_id_uidx` enforces unique non-null Sales ticket
  issue linkage.
- Tickera import/upsert behavior is source-safe: conflicting
  `fastcheck_sales` attendees are not overwritten.
- Full authoritative reconciliation writes are source-scoped to Tickera rows.
- Mobile attendee JSON shape remains unchanged; internal VS-02 fields remain
  unexposed.
- Scanner authority remains attendee `scan_eligibility`-based, with no handover
  to Sales `scanner_status`.

## Decisions Applied

- `event_scoped_first` remains in effect.
- Attendees remain Ecto-backed (no Ash Attendee resource introduced).
- `TicketIssue.attendee_id` remains external/nullable linkage; no Attendee FK
  changes were introduced in VS-02.
- Existing `FastCheck.Attendees.ReasonCodes` helpers remain authoritative for
  stable reason-code strings.
- No mobile API contract expansion for VS-02 internal fields.

## Boundaries Still Enforced

- No ticket issuance bridge.
- No QR/token generation.
- No Paystack integration.
- No Meta/WhatsApp integration.
- No Redis inventory ownership changes.
- No Oban worker additions for Sales flows.
- No Android runtime changes.
- No scanner hot-path rewrite.
- No customer/admin Sales UI.
- No Ash Attendee resource or Sales workflow implementation.

## Tests Added Or Updated

- `test/fastcheck/attendees/origin_protection_test.exs` — default source,
  source constraint, partial unique linkage, Tickera conflict protection,
  source-scoped reconciliation behavior, and scanner rejection compatibility.
- `test/fastcheck/events/sync_test.exs` — full-sync preserves absent
  `fastcheck_sales` attendee.
- `test/fastcheck_web/controllers/mobile/sync_controller_test.exs` — internal
  VS-02 fields not serialized in mobile attendee payloads.
- `test/fastcheck/sales/core_resource_boundary_test.exs` — narrowed historical
  changed-file prefix assertion only.
- `test/fastcheck/sales/vs_01e_boundary_test.exs` — narrowed historical
  changed-file prefix assertion only.
- `test/fastcheck/sales/vs_01f_boundary_test.exs` — narrowed historical
  changed-file prefix assertion only.

## Verification Reported

PR #343 reported:

- `mix deps.get`
- `mix format --check-formatted`
- `mix compile --warnings-as-errors`
- `mix test test/fastcheck/attendees/origin_protection_test.exs`
- `mix test test/fastcheck/attendees/reconciliation_test.exs`
- `mix test test/fastcheck/attendees/scan_test.exs`
- `mix test test/fastcheck/events/sync_test.exs`
- `mix test test/fastcheck_web/controllers/mobile/sync_controller_test.exs`
- `mix test test/fastcheck/sales/`
- `mix test`
- `mix precommit`

Reviewer follow-up docs patch also reported:

- `mix format --check-formatted`
- `mix compile --warnings-as-errors`
- `mix test test/fastcheck/attendees/origin_protection_test.exs`

## Known Limitations

- VS-02 does not implement ticket issuance/write-path creation of
  `fastcheck_sales` attendees.
- VS-02 does not implement Sales-side revocation workflow orchestration.
- VS-02 does not add VS-10 sync aggregation behavior.
- VS-02 does not expose new internal fields to mobile/client contracts.

## Next Agent Guidance

- Reuse the existing Ecto attendee ownership boundary in
  `lib/fastcheck/attendees.ex`, `lib/fastcheck/attendees/attendee.ex`, and
  `lib/fastcheck/attendees/reconciliation.ex`; do not recreate parallel
  ownership logic elsewhere.
- Keep `source` semantics authoritative in attendee rows; do not infer Sales
  origin from `sales_ticket_issue_id` alone.
- Preserve `FastCheck.Attendees.ReasonCodes` helper usage; avoid introducing new
  ad hoc reason strings for existing semantics.
- Keep mobile serializer shape stable in
  `lib/fastcheck_web/controllers/mobile/sync_controller.ex`; do not leak VS-02
  internal fields.
- Keep all VS-02 regressions and existing attendee/events/mobile/sales boundary
  suites green.

## Next Slice

Recommended next slice: VS-09 — Ticket Issuance Bridge

Entry condition: VS-02 remains merged and green; next implementation must build
on the new attendee origin contract and preserve Tickera/Sales ownership
protection, scanner eligibility authority, and mobile response compatibility.
