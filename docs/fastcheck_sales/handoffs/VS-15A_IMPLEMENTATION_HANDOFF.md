# VS-15A Implementation Handoff

## Status

Merged.

PR: #394 — feat(tickets): VS-15A core revocation and scanner visibility  
Merge commit: `2c55888681c55975ae541b0f7d351dd59d8f34e8`  
Implementation head: `a162c9f18596a3f5ae51aa63e690008e1cc05b3f`  
Merged at: 2026-06-23T21:16:10Z  
Branch: `cursor/vs-15a-core-revocation-scanner-visibility`  
CI: run 28057290508 green on implementation head

## What Changed

VS-15A added the core Sales revocation path so issued `TicketIssue` rows can be
revoked and linked attendees become scanner-ineligible immediately.

`FastCheck.Tickets.Revocation` is the authoritative entrypoint for
`revoke_ticket_issue/2` and bounded `revoke_order_tickets/2`. It locks ticket
and attendee rows, marks `TicketIssue` revoked via Ash `:mark_revoked`, calls
`FastCheck.Tickets.ScannerVisibility.mark_not_scannable/2`, bumps
`event_sync_version` inside the transaction (`skip_cache_invalidation: true`),
and invalidates attendee caches after commit.

Batch order revoke uses one outer `Repo.transaction` with per-ticket savepoints;
the aggregated mobile sync bump runs inside that outer transaction and rolls back
all batch mutations on failure. Cache invalidation remains post-commit.

No `RevokeTicketWorker`, Paystack refund APIs, WhatsApp/email delivery,
admin/operator LiveView UI, Order `refunded` transitions, or scanner-core
acceptance rewrites were added.

Planning context (not implementation truth):
`docs/fastcheck_sales/feature_packs/0035_VS-15A_core-revocation-and-scanner-visibility/VS-15A-FEATURE_PACK.md`.

## Files Changed

- `lib/fastcheck/tickets/revocation.ex` — core revocation boundary;
  actor/event-scope authorization; single-ticket and bounded order-batch revoke;
  row locks; sync bump in transaction; post-commit cache invalidation; telemetry.
- `lib/fastcheck/tickets/scanner_visibility.ex` — sets `Attendee.scan_eligibility`
  to `not_scannable` and appends `AttendeeInvalidationEvent` (idempotent when
  already ineligible).
- `lib/fastcheck/sales/ticket_issue.ex` — Ash `:mark_revoked` update action with
  policies and `StateTransition` audit; `:list_issued_by_order` read for SQL-level
  `sales_order_id` + `status == "issued"` filtering.
- `lib/fastcheck/events/mobile_sync_version_aggregator.ex` —
  `after_attendee_invalidated/5` for revocation visibility bumps.
- `lib/fastcheck/observability/telemetry_names.ex` — four new revocation/scanner
  visibility telemetry events (23 → 27).
- `priv/repo/migrations/20260624120000_add_ticket_issue_order_status_index.exs` —
  `sales_ticket_issues_sales_order_id_status_idx` on `(sales_order_id, status)`.
- `test/fastcheck/tickets/revocation_test.exs` — revoke flows, idempotency,
  scanner/DbAuthority denial, actor scope, batch sync bump once, batch sync-failure
  rollback and retry.
- `test/fastcheck/tickets/scanner_visibility_test.exs` — attendee ineligibility and
  invalidation append/idempotency.
- `test/fastcheck/tickets/revocation_boundary_test.exs` — entrypoints exist; no
  Paystack/WhatsApp/Oban/RevokeTicketWorker/mark_refunded references.
- `test/fastcheck/events/mobile_sync_version_aggregator_test.exs` —
  `after_attendee_invalidated/5` and `skip_cache_invalidation` behavior.
- `test/fastcheck/sales/ticket_issue_test.exs` — `:mark_revoked` transition
  metadata safety.
- `test/fastcheck/sales/ticket_page_test.exs` — `Revocation` writer drives
  `:ticket_revoked` secure-page state via `DeliveryToken.revoked?/1`.
- `test/fastcheck/sales/ticket_and_delivery_resource_skeletons_test.exs`,
  `vs_01g_index_and_migration_verification_test.exs`,
  `telemetry_names_test.exs` — allowlist/index/telemetry count updates only.

## Contracts Now Available

- `FastCheck.Tickets.Revocation.revoke_ticket_issue/2` — single-ticket revoke;
  returns `{:ok, %{status: :revoked | :already_revoked, ...}}` or structured errors.
- `FastCheck.Tickets.Revocation.revoke_order_tickets/2` — bounded batch (max 50
  issued tickets); partial per-ticket failures collected; order moves to
  `manual_review` on partial failure.
- `FastCheck.Tickets.ScannerVisibility.mark_not_scannable/2` — attendee
  ineligibility + invalidation event writer (do not duplicate from LiveView).
- `TicketIssue` Ash `:mark_revoked` — durable revoked audit state on
  `sales_ticket_issues` (`status`, `revoked_at`, `revocation_reason`,
  `scanner_status`, `delivery_token_expires_at`).
- `TicketIssue` `:list_issued_by_order` — issued-only order queries for batch revoke.
- `MobileSyncVersionAggregator.after_attendee_invalidated/5` — invalidation sync
  bump helper with `:skip_cache_invalidation` support.
- Index `sales_ticket_issues_sales_order_id_status_idx` for order+status lookups.
- Revoked tickets are denied by existing `Scan.check_in/4` and `DbAuthority.check/2`
  via `scan_eligibility = "not_scannable"`; secure ticket page returns
  `:ticket_revoked` when delivery token is revoked.

## Decisions Applied

- Core revocation path is service-level (`Revocation`), not LiveView/worker-owned.
- Scanner safety uses existing attendee `scan_eligibility` + invalidation events;
  no scanner-core rewrite.
- Durable `event_sync_version` bump inside transaction; cache invalidation
  post-commit (Issuer pattern).
- Batch order revoke bumps sync once per successful batch window; sync failure
  rolls back all batch mutations.
- Admin/operator actors require `reason` and non-empty `allowed_event_ids` matching
  `order.event_id`; system requires audit context (`correlation_id` or
  `idempotency_key`); `customer_session` forbidden.
- Attendee and `TicketIssue` rows locked `FOR UPDATE` inside transaction; attendee
  revalidated for `ticket_code` and `event_id` after lock.
- `event_scoped_first`; `organization_id` deferred.
- Telemetry and logs use `Redactor` / operational metadata; no PII or ticket codes
  in logs (tests enforce).

## Boundaries Still Enforced

- No admin/operator refund/revocation LiveView or dashboard actions (VS-15B).
- No Paystack refund API calls or payment reversal orchestration.
- No `RevokeTicketWorker` or new Oban queue for revocation.
- No Order `refunded` / broad fulfillment-state transitions from revocation alone.
- No WhatsApp, email, or `DeliveryAttempt` workflow changes.
- No Redis inventory mutation.
- No mobile API DTO or Android scanner client changes.
- No unique constraint on invalidation events (minimal idempotency only).
- Revocation modules must not reference Paystack, WhatsApp, Oban workers, or
  `mark_refunded` (boundary test guards).

## Tests Added Or Updated

- `test/fastcheck/tickets/revocation_test.exs` — issued revoke, idempotent retry,
  scanner/DbAuthority denial, actor authorization, event scope, missing attendee,
  PII-safe logs, 3-ticket batch single sync bump, batch sync-failure rollback,
  retry after failed batch.
- `test/fastcheck/tickets/scanner_visibility_test.exs` — `mark_not_scannable/2`
  mutation and invalidation append.
- `test/fastcheck/tickets/revocation_boundary_test.exs` — module boundaries and
  forbidden later-slice API references.
- `test/fastcheck/events/mobile_sync_version_aggregator_test.exs` —
  `after_attendee_invalidated/5`.
- `test/fastcheck/sales/ticket_issue_test.exs` — `:mark_revoked` audit metadata.
- `test/fastcheck/sales/ticket_page_test.exs` — revocation writer → secure page
  `:ticket_revoked`.
- Skeleton/index/telemetry tests — resource action allowlist and index verification.

## Verification Reported

From PR #394 test plan:

```bash
mix test test/fastcheck/tickets/revocation_test.exs
mix test test/fastcheck/tickets/scanner_visibility_test.exs
mix test test/fastcheck/tickets/revocation_boundary_test.exs
mix test test/fastcheck/events/mobile_sync_version_aggregator_test.exs
mix test test/fastcheck/sales/ticket_page_test.exs
mix test test/fastcheck/sales/ticket_issue_test.exs
mix precommit
```

Results reported:

- `mix precommit` — 888 tests, 0 failures
- CI run 28057290508 — success on head `a162c9f`

## Known Limitations

- No operator/admin UI to trigger refund/revocation; callers must invoke
  `Revocation` directly until VS-15B.
- No Paystack refund integration or automated payment reversal.
- No dedicated revocation worker; synchronous service calls only.
- Order-level revoke partial failures move order to `manual_review` but do not
  implement refund state transitions.
- Pending `TicketIssue` rows require explicit `source` in
  `~w(cancel cleanup cancellation system_reconciliation)` to revoke.
- Invalidation idempotency is minimal (no unique invalidation schema).

## Next Agent Guidance

**Reuse:**

- `FastCheck.Tickets.Revocation` for all scanner-visible revocation (VS-15B must
  call this, not mutate attendees directly).
- `FastCheck.Tickets.ScannerVisibility` only from `Revocation` (or future
  approved core paths).
- `TicketIssue.mark_revoked` via `Revocation` with service-level authorization;
  do not bypass with raw SQL/Ash updates from UI.
- `MobileSyncVersionAggregator.after_attendee_invalidated/5` / batch
  `after_attendees_created/3` with `skip_cache_invalidation: true` inside
  transactions.
- Actor options: `actor_type`, `actor_id`, `reason`, `allowed_event_ids`,
  `correlation_id`, `idempotency_key`.

**Do not:**

- Recreate parallel revocation logic in LiveView, workers, or payment modules.
- Mutate `Attendee.scan_eligibility` or append invalidation rows from admin UI.
- Bump `event_sync_version` outside the revocation transaction without matching
  Issuer/VS-15A cache post-commit pattern.
- Add Paystack/WhatsApp/delivery behavior to `Revocation` or `ScannerVisibility`.
- Filter issued tickets in Elixir for batch revoke; use `:list_issued_by_order`.

**Keep green:**

- `test/fastcheck/tickets/revocation_test.exs`
- `test/fastcheck/tickets/scanner_visibility_test.exs`
- `test/fastcheck/tickets/revocation_boundary_test.exs`
- `test/fastcheck/sales/ticket_page_test.exs`
- `test/fastcheck/events/mobile_sync_version_aggregator_test.exs`
- `mix precommit`

## Next Slice

Recommended next slice: **VS-15B — Admin Refund and Revocation Operations**

Entry condition:

- VS-15A merged; `FastCheck.Tickets.Revocation` and `ScannerVisibility` on `main`.
- VS-13 manual-review operations and VS-12 admin dashboard remain merged.
- VS-15B must call `Revocation` for scanner-safe revoke; must not duplicate
  attendee/invalidation mutation or implement a second revocation mechanism.
- Admin/operator UI must pass `reason`, `allowed_event_ids`, and audit context
  through to `Revocation` opts.
