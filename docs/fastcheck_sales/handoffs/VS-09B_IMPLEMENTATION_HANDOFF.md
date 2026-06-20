# VS-09B Implementation Handoff

## Status

Merged.

PR: #376 — feat: implement VS-09B attendee creation bridge  
Merge commit: `f548a247368fe1d3932f548dce62f28d59e38941`  
Merged at: 2026-06-20T13:41:08Z  
Branch: `vs-09b-attendee-creation-bridge`

## What Changed

VS-09B implemented the attendee-creation bridge inside
`FastCheck.Tickets.Issuer.issue_order/2`. Verified paid Sales orders now create
or reuse existing Ecto `FastCheck.Attendees.Attendee` rows, one row per
deterministic purchased ticket unit, using Sales lineage encoded in
`source_reference`.

The slice also added the missing partial unique attendee index for
`fastcheck_sales` source references, a matching changeset constraint, and focused
tests for idempotency, concurrency, rollback safety, Tickera protection, scanner
compatibility, and mobile sync visibility.

No `TicketIssue` rows, order final transitions, workers, payment changes, Redis
inventory changes, Android changes, delivery changes, or scanner rule changes
were added.

## Files Changed

- `lib/fastcheck/tickets/issuer.ex` — implements VS-09B attendee create/reuse
  under one `FastCheck.Repo` transaction with advisory locking, Sales
  precondition checks, deterministic source references, bounded ticket-code
  retry, and attendee cache invalidation after success.
- `lib/fastcheck/attendees/attendee.ex` — adds the changeset unique constraint
  for the Sales source-reference partial unique index.
- `priv/repo/migrations/20260620111000_add_fastcheck_sales_attendee_source_reference_unique_index.exs`
  — creates `attendees_fastcheck_sales_source_reference_uidx` on
  `[:source, :source_reference]` where `source = 'fastcheck_sales'` and
  `source_reference IS NOT NULL`.
- `test/fastcheck/tickets/issuer_attendee_bridge_test.exs` — verifies attendee
  creation, deterministic source references, retry reuse, concurrency safety,
  invalid preconditions, no `TicketIssue` creation, and rollback on later-unit
  source-reference conflict.
- `test/fastcheck/attendees/origin_protection_test.exs` — verifies duplicate
  `fastcheck_sales` source references are rejected, non-Sales duplicate behavior
  is unchanged, and Sales-origin attendees survive Tickera reconciliation.
- `test/fastcheck/attendees/scan_test.exs` — verifies active Sales-origin
  attendees scan through the existing scanner path.
- `test/fastcheck_web/controllers/mobile/sync_controller_test.exs` — verifies
  active Sales-origin attendees appear in mobile sync without exposing internal
  lineage fields.
- `test/fastcheck/tickets/issuer_boundary_test.exs` — updates boundary tests for
  the implemented VS-09B issuer while later-slice paths remain forbidden.
- `test/fastcheck/tickets/ticket_token_boundary_test.exs` — keeps token/delivery
  boundaries aligned with VS-09B scope.

## Contracts Now Available

- `FastCheck.Tickets.Issuer.issue_order/2` is the authoritative attendee bridge
  entrypoint for Sales-paid orders.
- Issuer uses a single `FastCheck.Repo.transaction/1` and
  `pg_advisory_xact_lock(order_id)`.
- Issuer preconditions require:
  - order status `"paid_verified"` or `"fulfillment_queued"`;
  - at least one `verified_success` payment attempt matching order amount and
    currency;
  - checkout session status `"paid"`.
- Deterministic attendee lineage is encoded as:
  `source = "fastcheck_sales"` and
  `source_reference = "sales:{order_id}:{order_line_id}:{sequence}"`.
- VS-09B does not add physical `attendees.sales_order_line_id` or
  `attendees.line_item_sequence` columns.
- Successful calls return `:attendees_ready`; fully reused calls return
  `:attendees_already_ready`.
- Returned attendees include only `id` and `source_reference`, which VS-09C can
  consume for audit linking.
- `sales_ticket_issue_id` remains `nil` until VS-09C links `TicketIssue` rows.
- The DB enforces unique Sales attendee source references with
  `attendees_fastcheck_sales_source_reference_uidx`.
- Existing scanner lookup remains `event_id + ticket_code`.

## Decisions Applied

- Use `source_reference` as the deterministic line-level lineage key.
- Reuse Ecto `FastCheck.Attendees.Attendee`; do not move attendee or scanner
  paths into Ash.
- Reuse `FastCheck.Tickets.CodeGenerator.generate/0` for ticket codes.
- Keep Sales order, line, payment, and checkout reads in the issuer; keep attendee
  writes Ecto-backed.
- Roll back every `{:error, reason}` produced inside the issuer transaction.
- Invalidate only existing attendee/event caches after successful attendee
  creation or reuse.
- Do not bump the VS-10 event sync aggregator in this slice.

## Boundaries Still Enforced

- No `FastCheck.Sales.TicketIssue` creation or linking.
- No order transition to `ticket_issued` or `partially_issued`.
- No `IssueTicketsWorker` implementation or Oban queue config.
- No Paystack, webhook, or payment module changes.
- No Redis inventory reads or writes.
- No WhatsApp, Meta, email, ticket delivery, QR payload, or delivery token flow.
- No Android DTO or mobile API shape changes.
- No scanner rule changes; existing `scan_eligibility` remains authoritative.
- No handoff docs were changed in the implementation PR.

## Tests Added Or Updated

- `test/fastcheck/tickets/issuer_attendee_bridge_test.exs` — core VS-09B bridge
  behavior, retry/idempotency, concurrency, precondition failures, no
  `TicketIssue` rows, and rollback on source-reference conflict.
- `test/fastcheck/attendees/origin_protection_test.exs` — DB uniqueness and
  Tickera reconciliation protection for Sales-origin attendees.
- `test/fastcheck/attendees/scan_test.exs` — active Sales-origin attendee scanner
  acceptance through the existing scanner path.
- `test/fastcheck_web/controllers/mobile/sync_controller_test.exs` — active
  Sales-origin attendee mobile sync visibility without internal lineage fields.
- `test/fastcheck/tickets/issuer_boundary_test.exs` and
  `test/fastcheck/tickets/ticket_token_boundary_test.exs` — boundary updates for
  VS-09B while later-slice ticket issue, worker, payment, and delivery paths stay
  forbidden.

## Verification Reported

From PR #376 body:

```bash
mix test test/fastcheck/tickets/issuer_attendee_bridge_test.exs test/fastcheck/attendees/origin_protection_test.exs test/fastcheck/attendees/scan_test.exs test/fastcheck_web/controllers/mobile/sync_controller_test.exs
mix test test/fastcheck/tickets/
mix test test/fastcheck/attendees/reconciliation_test.exs
mix test test/fastcheck/sales/payments/
mix test test/fastcheck/sales/vs_01g_index_and_migration_verification_test.exs
mix compile --warnings-as-errors
mix test
mix precommit
```

Additional review-patch verification before merge:

- `mix test test/fastcheck/tickets/issuer_attendee_bridge_test.exs` — 7 tests,
  0 failures
- `mix test test/fastcheck/tickets/` — 55 tests, 0 failures
- `mix precommit` — 753 tests, 0 failures, 4 skipped
- GitHub Actions: `Test (Elixir 1.17.3 OTP 26.2)` passed

## Known Limitations

- `TicketIssue` rows are still not created, linked, or reused.
- Order fulfillment states are not changed by VS-09B.
- Returned attendee IDs/source references are ready for VS-09C, but audit tokens,
  ticket issue states, and order finalization are still absent.
- Manual-review conflicts return reason atoms only; no admin manual-review UI was
  added.
- Event sync version aggregation remains deferred to VS-10.
- Delivery, secure ticket page, WhatsApp, revocation, and refund behavior remain
  later-slice work.

## Next Agent Guidance

**Reuse:**

- `FastCheck.Tickets.Issuer.issue_order/2` as the only attendee creation/reuse
  entrypoint for Sales-paid orders.
- The returned `%{id: attendee_id, source_reference: source_reference}` entries
  when adding VS-09C `TicketIssue` audit links.
- Existing attendee rows and `sales_ticket_issue_id` for linking; do not recreate
  attendees in VS-09C.
- `source_reference = "sales:{order_id}:{order_line_id}:{sequence}"` as the
  deterministic lineage key.
- `attendees_fastcheck_sales_source_reference_uidx` and
  `Attendee.changeset/2` constraint for duplicate safety.
- Existing issuer bridge, origin protection, scanner, and mobile sync regression
  tests.

**Do not:**

- Add `attendees.sales_order_line_id` or `attendees.line_item_sequence`.
- Bypass `FastCheck.Tickets.Issuer` with payment/webhook/WhatsApp/controller
  issuance paths.
- Create another attendee bridge helper or alternate source-reference format.
- Move scanner, mobile sync, Tickera reconciliation, or attendees into Ash.
- Treat `:attendees_ready` as full ticket issuance; VS-09C must still create
  `TicketIssue` audit links and handle order transitions according to its pack.

**Keep green:**

- `test/fastcheck/tickets/issuer_attendee_bridge_test.exs`
- `test/fastcheck/tickets/`
- `test/fastcheck/attendees/origin_protection_test.exs`
- `test/fastcheck/attendees/reconciliation_test.exs`
- `test/fastcheck/attendees/scan_test.exs`
- `test/fastcheck_web/controllers/mobile/sync_controller_test.exs`
- `mix precommit`

## Next Slice

Recommended next slice: **VS-09C — TicketIssue Audit Linking**

Entry condition:

- VS-09B is merged on `main`.
- The attendee bridge returns deterministic attendee IDs and source references.
- `attendees_fastcheck_sales_source_reference_uidx` is migrated.
- Scanner/mobile/Tickera protections for Sales-origin attendees remain green.
- VS-09C must consume existing attendees from VS-09B, create/reuse
  `FastCheck.Sales.TicketIssue` audit rows, and avoid changing attendee
  creation semantics unless its feature pack explicitly requires it.
