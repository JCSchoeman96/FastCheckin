# VS-02 Attendee Origin Protection Plan

## Plan Metadata
- **Plan ID:** VS-02-attendee-origin-protection
- **Plan version:** v1
- **Status:** Approved after reviewer feedback
- **Scope:** VS-02 Attendee Origin Protection
- **Branch:** `vs-02-attendee-origin-protection`
- **Last updated:** 2026-06-16

## Authority / Source of Truth
- **Active contract (canonical):** this file is the active implementation contract for VS-02.
- **Feature pack spec:** [docs/fastcheck_sales/feature_packs/0012_VS-02_attendee-origin-protection/VS-02-FEATURE_PACK.md](docs/fastcheck_sales/feature_packs/0012_VS-02_attendee-origin-protection/VS-02-FEATURE_PACK.md)
- **Predecessor handoffs:** [docs/fastcheck_sales/handoffs/README.md](docs/fastcheck_sales/handoffs/README.md), [docs/fastcheck_sales/handoffs/VS-01B_IMPLEMENTATION_HANDOFF.md](docs/fastcheck_sales/handoffs/VS-01B_IMPLEMENTATION_HANDOFF.md), [docs/fastcheck_sales/handoffs/VS-01C_IMPLEMENTATION_HANDOFF.md](docs/fastcheck_sales/handoffs/VS-01C_IMPLEMENTATION_HANDOFF.md), [docs/fastcheck_sales/handoffs/VS-01D_IMPLEMENTATION_HANDOFF.md](docs/fastcheck_sales/handoffs/VS-01D_IMPLEMENTATION_HANDOFF.md), [docs/fastcheck_sales/handoffs/VS-01F_IMPLEMENTATION_HANDOFF.md](docs/fastcheck_sales/handoffs/VS-01F_IMPLEMENTATION_HANDOFF.md), [docs/fastcheck_sales/handoffs/VS-01G_IMPLEMENTATION_HANDOFF.md](docs/fastcheck_sales/handoffs/VS-01G_IMPLEMENTATION_HANDOFF.md)
- **Conflict rule:** this plan wins over older slice notes for VS-02 scope.

## Revision Log
- **v1** - Initial canonical VS-02 plan created with approved guardrails and explicit implementation/test boundaries.

## Baseline and Constraints
- Attendees are Ecto-backed in [lib/fastcheck/attendees/attendee.ex](lib/fastcheck/attendees/attendee.ex) and **must remain Ecto**.
- Tickera sync and reconciliation currently run through [lib/fastcheck/attendees.ex](lib/fastcheck/attendees.ex), [lib/fastcheck/attendees/reconciliation.ex](lib/fastcheck/attendees/reconciliation.ex), and [lib/fastcheck/events/sync.ex](lib/fastcheck/events/sync.ex).
- Scanner authority remains `scan_eligibility` / `ineligibility_reason`; do not use Sales `scanner_status` for scanner decisions.
- No mobile contract or DTO changes; keep internal attendee origin/linkage fields unexposed in mobile responses.

## Branch Workflow
- `git switch main`
- `git pull origin main`
- `git switch -c vs-02-attendee-origin-protection`

## Implementation Scope (Only)
1. Add attendee origin-protection migration at:
   - `priv/repo/migrations/<actual_current_timestamp>_add_attendee_origin_protection.exs`
2. Update attendee schema/types/changeset in:
   - [lib/fastcheck/attendees/attendee.ex](lib/fastcheck/attendees/attendee.ex)
3. Protect Tickera bulk upsert conflicts in:
   - [lib/fastcheck/attendees.ex](lib/fastcheck/attendees.ex)
4. Source-scope reconciliation writes in:
   - [lib/fastcheck/attendees/reconciliation.ex](lib/fastcheck/attendees/reconciliation.ex)
5. Add/adjust tests:
   - [test/fastcheck/attendees/origin_protection_test.exs](test/fastcheck/attendees/origin_protection_test.exs)
   - [test/fastcheck/events/sync_test.exs](test/fastcheck/events/sync_test.exs)
   - [test/fastcheck_web/controllers/mobile/sync_controller_test.exs](test/fastcheck_web/controllers/mobile/sync_controller_test.exs)
   - Minimal narrowing only if needed in [test/fastcheck/sales/core_resource_boundary_test.exs](test/fastcheck/sales/core_resource_boundary_test.exs), [test/fastcheck/sales/vs_01e_boundary_test.exs](test/fastcheck/sales/vs_01e_boundary_test.exs), [test/fastcheck/sales/vs_01f_boundary_test.exs](test/fastcheck/sales/vs_01f_boundary_test.exs)
6. Add slice documentation:
   - [docs/fastcheck_sales/slices/VS-02_ATTENDEE_ORIGIN_PROTECTION.md](docs/fastcheck_sales/slices/VS-02_ATTENDEE_ORIGIN_PROTECTION.md)

## Data and Migration Contract
- Add to `attendees`:
  - `source` (string, non-null, default `"tickera"`)
  - `source_reference` (string, nullable)
  - `sales_order_id` (integer, nullable)
  - `sales_ticket_issue_id` (integer, nullable)
  - `revoked_at` (utc_datetime, nullable)
  - `revocation_reason` (string/text, nullable)
- Add check constraint:
  - `attendees_source_valid`: source in (`tickera`, `fastcheck_sales`, `manual`, `import`, `test`)
- Add indexes:
  - `attendees_source_idx` on `[:source]`
  - `attendees_source_source_reference_idx` on `[:source, :source_reference]`
  - `attendees_sales_ticket_issue_id_uidx` unique on `[:sales_ticket_issue_id]` where not null
  - `attendees_sales_order_id_idx` on `[:sales_order_id]` where not null
  - `attendees_event_id_source_idx` on `[:event_id, :source]`

## Tickera Ownership Protection Rules
- Tickera import must set incoming `source = "tickera"`.
- Tickera conflict updates must only update existing rows where `source = "tickera"` (legacy-null handling only if still present at runtime).
- Conflicting `source = "fastcheck_sales"` rows must not be overwritten.
- Use existing reason-code helpers where possible; avoid new magic strings in implementation/tests:
  - `FastCheck.Attendees.ReasonCodes.revoked()`
  - `FastCheck.Attendees.ReasonCodes.source_missing_from_authoritative_sync()`
- Reconciliation writes must be source-scoped:
  - `mark_imported_seen` => only Tickera source
  - `reactivate_imported` => only Tickera source
  - `mark_absent_not_scannable` => only Tickera source
  - invalidation inserts => only affected Tickera-origin attendees

## Attendee Changeset Rules
- `FastCheck.Attendees.Attendee.changeset/2` must cast new origin/linkage/revocation fields.
- Changeset must wire DB-backed constraints for:
  - `attendees_source_valid`
  - `attendees_sales_ticket_issue_id_uidx`

## Required Tests (RED->GREEN)
- Origin field/constraint/index coverage (including duplicate non-null `sales_ticket_issue_id`).
- Reconciliation behavior split:
  - Tickera-origin absent attendee becomes `not_scannable`.
  - Sales-origin absent attendee remains unchanged/active.
- Tickera upsert conflict protection for `fastcheck_sales` rows.
- Scanner regression proving existing `scan_eligibility` rejection still blocks revoked-style rows.
- Mobile sync regression proving new internal fields are not serialized:
  - `source`, `source_reference`, `sales_order_id`, `sales_ticket_issue_id`, `revoked_at`, `revocation_reason`.
- Mobile API contract freeze: do not add, rename, or remove existing mobile response fields.

## Verification Gate
Run, in order:
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

Optional migration safety:
- `MIX_ENV=test mix ecto.rollback -n 1 && MIX_ENV=test mix ecto.migrate`
- rerun `mix test test/fastcheck/attendees/origin_protection_test.exs`

## Explicit Non-Goals
- No Ash attendee resource.
- No Sales `TicketIssue` workflow/behavior changes.
- No ticket issuance bridge, QR/token generation, Paystack, WhatsApp/Meta.
- No Redis inventory or Oban worker work.
- No scanner hot-path rewrite.
- No Android changes.
- No mobile API contract changes.
- No dependency upgrades.
