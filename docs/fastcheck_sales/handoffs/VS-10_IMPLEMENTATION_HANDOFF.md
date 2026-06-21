# VS-10 Implementation Handoff

## Status

Merged.

PR: #382 — feat(events): add VS-10 mobile sync version aggregator  
Merge commit: `3552ba2ab8828fc759370b0ef8a614c0248ea67a`  
Merged at: 2026-06-21T07:01:57Z  
Branch: `vs-10-event-sync-version-aggregator`

## What Changed

VS-10 added the Sales-origin mobile sync visibility boundary for issued
Sales-created attendees. Fresh `FastCheck.Tickets.Issuer.issue_order/2` calls now
bump `events.event_sync_version` exactly once inside the issuer transaction for a
fresh `:ticket_issued` result, then invalidate attendee caches best-effort after
commit through the new aggregator boundary.

The slice also added an explicit non-bang event sync version bump helper that can
detect missing event rows. Existing mobile sync response shapes, scanner
acceptance, Android code, Redis inventory, payment, WhatsApp, delivery, workers,
migrations, dependencies, and handoff docs were not changed in the implementation
PR.

## Files Changed

- `lib/fastcheck/events.ex` — adds `bump_event_sync_version/1`, returning `:ok`
  or `{:error, :event_not_found}`, while preserving existing
  `bump_event_sync_version!/1` behavior.
- `lib/fastcheck/events/mobile_sync_version_aggregator.ex` — new
  Sales-origin visibility boundary with `after_attendees_created/3` and
  best-effort attendee cache invalidation.
- `lib/fastcheck/tickets/issuer.ex` — calls the aggregator inside the existing
  issuer transaction for fresh `:ticket_issued`; skips normal `:already_issued`
  retries; delegates post-commit cache invalidation to the aggregator.
- `test/fastcheck/events/mobile_sync_version_aggregator_test.exs` — verifies
  aggregator return contract, one version bump, missing/invalid event handling,
  ticket-code normalization, cache invalidation, and safe cache-failure logging.
- `test/fastcheck/tickets/issuer_mobile_sync_test.exs` — verifies fresh issuance
  bumps once, retries do not double-bump, aggregation failure rolls back
  issuance, and mobile sync still returns issued Sales attendees with unchanged
  response shape.

## Contracts Now Available

- `FastCheck.Events.MobileSyncVersionAggregator.after_attendees_created/3` is the
  approved Sales-origin boundary for attendee creation visibility in mobile sync.
- `FastCheck.Events.bump_event_sync_version/1` is available when callers need
  missing-event detection; `bump_event_sync_version!/1` remains unchanged for
  existing Tickera/reconciliation paths.
- Fresh successful Sales issuance increments `events.event_sync_version` once per
  order transaction, not once per ticket.
- A normal `:already_issued` retry does not increment `event_sync_version` again.
- Durable sync-version bump failure inside issuer causes issuance rollback.
- Attendee event-list cache and attendee ID caches are invalidated via existing
  attendee cache facades; cache invalidation failure is logged safely and does
  not undo a successful durable bump.
- Mobile sync API response shape is guarded by tests and remains unchanged.

## Decisions Applied

- Keep Sales scanner visibility changes centralized in the Events aggregator.
- Durable `event_sync_version` bump is correctness-critical and belongs inside
  the issuer transaction for fresh issuance.
- Cache invalidation is freshness-critical but best-effort after the durable
  bump.
- Do not log ticket codes, buyer PII, token material, provider payloads, scanner
  secrets, or idempotency keys from the aggregator.
- Leave existing Tickera reconciliation behavior as an approved parallel bump
  path.
- Keep scanner/mobile/Attendee runtime paths Ecto/Phoenix-backed; do not move
  them into Ash.

## Boundaries Still Enforced

- No scanner acceptance logic changes.
- No mobile API DTO or response shape changes.
- No Android changes.
- No router/auth changes.
- No attendee schema or migration changes.
- No TicketIssue creation changes beyond the existing issuer behavior.
- No Paystack, webhook, WhatsApp, Meta, email, delivery, `DeliveryAttempt`, Oban,
  or worker changes.
- No Redis inventory mutation.
- No revocation/refund implementation.
- No admin dashboard, analytics, or new PubSub protocol.

## Tests Added Or Updated

- `test/fastcheck/events/mobile_sync_version_aggregator_test.exs` — new
  aggregator contract and cache/logging tests.
- `test/fastcheck/tickets/issuer_mobile_sync_test.exs` — new issuer/mobile sync
  integration coverage for one bump, retry behavior, rollback, and response
  shape.

## Verification Reported

From PR #382:

```bash
mix compile --warnings-as-errors
mix test test/fastcheck/events/mobile_sync_version_aggregator_test.exs test/fastcheck/tickets/issuer_mobile_sync_test.exs
mix test test/fastcheck/tickets/issuer_retry_test.exs test/fastcheck/tickets/issuer_partial_failure_test.exs test/fastcheck/tickets/issuer_ticket_issue_linking_test.exs
mix test test/fastcheck/tickets/
mix test test/fastcheck/attendees/reconciliation_test.exs test/fastcheck/attendees/scan_test.exs
mix test test/fastcheck_web/controllers/mobile/sync_controller_test.exs
mix test test/fastcheck/sales/vs_01g_index_and_migration_verification_test.exs
mix format --check-formatted
mix test
mix precommit
```

Reported results:

- `mix test` — 783 tests, 0 failures, 4 skipped.
- `mix precommit` — 783 tests, 0 failures, 4 skipped.

## Known Limitations

- The aggregator currently implements attendee-created visibility only; future
  revocation/refund invalidation behavior remains VS-15A/VS-15B work.
- No new invalidation rows are written for Sales issuance because created
  attendees are visible through the existing active attendee sync path.
- No dashboard/stat PubSub protocol or analytics cache behavior was added.
- No post-merge VS-10 slice doc under `docs/fastcheck_sales/slices/` was added
  by the implementation PR; the feature pack and this handoff are the relevant
  docs for this boundary.

## Next Agent Guidance

Reuse:

- `FastCheck.Events.MobileSyncVersionAggregator.after_attendees_created/3` for
  Sales-origin attendee creation visibility.
- `FastCheck.Events.bump_event_sync_version/1` when missing-event detection is
  required.
- `FastCheck.Tickets.Issuer.issue_order/2` as the only paid-order issuance
  entrypoint.
- Existing attendee cache facade functions; do not construct Cachex keys in
  issuer or future Sales callers.
- Existing mobile sync endpoint and response shape.

Do not:

- Recreate a second sync-version bump/cache invalidation service.
- Bypass the issuer from webhooks, controllers, LiveViews, workers, WhatsApp, or
  delivery code.
- Move scanner, mobile sync, Tickera reconciliation, or Attendee runtime paths
  into Ash.
- Log ticket codes, buyer email/phone, QR/delivery tokens or hashes, raw provider
  payloads, scanner secrets, or idempotency keys.
- Change Tickera reconciliation unless a later slice explicitly owns that
  migration.

Keep green:

- `test/fastcheck/events/mobile_sync_version_aggregator_test.exs`
- `test/fastcheck/tickets/issuer_mobile_sync_test.exs`
- `test/fastcheck/tickets/`
- `test/fastcheck/attendees/reconciliation_test.exs`
- `test/fastcheck/attendees/scan_test.exs`
- `test/fastcheck_web/controllers/mobile/sync_controller_test.exs`
- `mix precommit`

## Next Slice

Recommended next slice: **VS-11 — Secure Ticket Page**

Entry condition:

- VS-10 is merged on `main`.
- Fresh Sales issuance still creates scanner-valid Attendees/TicketIssues and
  bumps `event_sync_version` once.
- Mobile sync response shape and scanner acceptance tests remain green.
- VS-11 should reuse existing TicketIssue/token foundations and must not alter
  scanner/mobile sync contracts unless its feature pack explicitly requires it.
