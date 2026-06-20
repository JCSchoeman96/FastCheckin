# VS-09D Implementation Handoff

## Status

Merged.

PR: #380 — test(tickets): add VS-09D issuance hardening coverage  
Merge commit: `329a4624936e2a7653ff265b3c8121766a5610e3`  
Merged at: 2026-06-20T19:01:24Z  
Branch: `vs-09d-issuance-retry-partial-failure-tests`

## What Changed

VS-09D hardened the VS-09C issuance path around
`FastCheck.Tickets.Issuer.issue_order/2`. It added retry, concurrency,
partial-row recovery, manual-review conflict, no-delivery, and audit-context
tests, with minimal issuer/resource changes required by those tests.

The issuer now builds one context from `opts` and passes it through attendee
creation/reuse, `TicketIssue.create_issued_link`, order finalization, and
manual-review transitions. Supplied `:correlation_id` and `:idempotency_key`
reach `Order` and `TicketIssue` StateTransition rows without being copied into
transition metadata.

The issuer also preflights deterministic attendee `source_reference` ownership
for the order before inserting attendees, so an ownership conflict moves the
order to `manual_review` without leaving earlier unit rows behind.

## Files Changed

- `lib/fastcheck/tickets/issuer.ex` — owns the hardened retry path, advisory
  lock transaction, attendee source-reference ownership preflight,
  TicketIssue reuse/linking, final order transition, manual-review conflict
  handling, and issuer audit context propagation.
- `lib/fastcheck/sales/order.ex` — reads correlation/idempotency values from
  Ash context or actor when recording Order StateTransition rows.
- `lib/fastcheck/sales/ticket_issue.ex` — reads correlation/idempotency values
  from Ash context or actor when recording `create_issued_link`
  StateTransition rows.
- `test/fastcheck/tickets/issuer_retry_test.exs` — proves duplicate sequential
  and concurrent issuance, final-transition idempotency, and safe audit context
  propagation.
- `test/fastcheck/tickets/issuer_partial_failure_test.exs` — proves durable
  pre-seeded Attendee/TicketIssue recovery, finalization retry,
  manual-review conflicts, VS-09C-shaped reused TicketIssue rows, and no
  `DeliveryAttempt` rows.

## Contracts Now Available

- `FastCheck.Tickets.Issuer.issue_order/2` remains the authoritative issuance
  entrypoint and is now covered for duplicate and concurrent calls.
- Sequential retry after full issuance returns idempotent success and does not
  append duplicate final Order transitions.
- Existing Sales-created Attendees can be reused to create missing TicketIssue
  rows.
- Existing issued TicketIssue rows can be reused to complete missing later
  order-line units.
- Orders with all Attendee/TicketIssue rows already present can be finalized
  from `paid_verified` without duplicating rows.
- Deterministic Attendee source-reference ownership conflicts move the order to
  `manual_review` and do not overwrite the conflicting attendee.
- TicketIssue or attendee-backlink conflicts move the order to `manual_review`
  and do not overwrite existing rows.
- Issuer-supplied `correlation_id` and `idempotency_key` are recorded on
  TicketIssue and Order StateTransitions.
- StateTransition metadata is guarded against `idempotency_key`, buyer PII,
  ticket codes, plaintext tokens, token hashes, and raw provider payloads.
- Issuance hardening still creates no `DeliveryAttempt` rows.

## Decisions Applied

- Treat VS-09D as a QA/hardening slice, not a feature-expansion slice.
- Use pre-seeded durable rows to model crash-after-commit or externally partial
  states.
- Do not add a failure seam; no test-only failure checkpoint was needed.
- Reuse VS-09B/VS-09C issuer, attendee, TicketIssue, Order, and
  StateTransition paths.
- Keep `correlation_id` and `idempotency_key` as StateTransition fields, not
  transition metadata.
- Keep scanner/mobile/Tickera behavior stable and outside Ash migration work.

## Boundaries Still Enforced

- No `IssueTicketsWorker` or Oban queue was added.
- No `DeliveryAttempt` behavior was added.
- No Paystack, webhook, checkout, or payment verification behavior changed.
- No WhatsApp, Meta, email, or secure ticket page delivery was added.
- No Redis inventory mutation or reservation behavior was added.
- No scanner route, mobile controller, Android DTO, Android app, router, or
  LiveView changes were made.
- No event sync aggregation was implemented; VS-10 owns that work.
- No admin/customer UI or manual-review operations UI was added.
- No implementation handoff docs were included in PR #380.

## Tests Added Or Updated

- `test/fastcheck/tickets/issuer_retry_test.exs` — sequential duplicate calls,
  concurrent duplicate calls, final Order transition idempotency, and audit
  context propagation without sensitive metadata leaks.
- `test/fastcheck/tickets/issuer_partial_failure_test.exs` — recovery from
  existing Attendees, existing partial TicketIssues, all rows present before
  final Order transition, attendee scanner conflicts, attendee source-reference
  ownership conflicts, TicketIssue conflicts, and no delivery attempts.

## Verification Reported

From PR #380 body:

```bash
mix test test/fastcheck/tickets/issuer_retry_test.exs test/fastcheck/tickets/issuer_partial_failure_test.exs
mix format lib/fastcheck/tickets/issuer.ex lib/fastcheck/sales/order.ex lib/fastcheck/sales/ticket_issue.ex test/fastcheck/tickets/issuer_retry_test.exs test/fastcheck/tickets/issuer_partial_failure_test.exs && mix compile --warnings-as-errors
mix test test/fastcheck/tickets/
mix test test/fastcheck/sales/ticket_issue_test.exs test/fastcheck/sales/vs_01g_index_and_migration_verification_test.exs test/fastcheck/attendees/origin_protection_test.exs test/fastcheck/attendees/reconciliation_test.exs test/fastcheck/attendees/scan_test.exs test/fastcheck_web/controllers/mobile/sync_controller_test.exs
mix test
mix precommit
```

Reported results:

- `mix test` — 772 tests, 0 failures, 4 skipped.
- `mix precommit` — 772 tests, 0 failures, 4 skipped.
- PR metadata showed CI success before merge.

Additional review-patch verification before merge:

- `mix test test/fastcheck/tickets/issuer_partial_failure_test.exs` — 7 tests,
  0 failures.
- `mix test test/fastcheck/tickets/issuer_retry_test.exs` — 4 tests,
  0 failures.
- `mix test test/fastcheck/tickets/` — 74 tests, 0 failures.
- `mix precommit` — 773 tests, 0 failures, 4 skipped.

## Known Limitations

- No background issuance worker exists yet.
- No customer ticket delivery exists yet.
- No secure ticket page, QR display page, resend flow, or delivery history
  exists yet.
- No event sync aggregation for issued Sales tickets exists yet.
- No scanner revocation/refund behavior exists yet.
- No admin/manual-review UI exists yet.

## Next Agent Guidance

Reuse `FastCheck.Tickets.Issuer.issue_order/2`; do not create another issuance
entrypoint. Reuse deterministic `sales:{order_id}:{order_line_id}:{sequence}`
source references, `attendees.sales_ticket_issue_id`,
`TicketIssue.create_issued_link`, `Order.mark_ticket_issued`, existing
StateTransition support, and the VS-08 token/hash helpers.

Do not bypass issuer conflict handling from webhooks, controllers, LiveViews,
workers, WhatsApp, or delivery code. Do not store plaintext customer-facing
tokens. Do not put ticket codes, token hashes, buyer PII, raw provider payloads,
or idempotency keys in transition metadata. Do not move scanner, mobile sync,
Tickera reconciliation, or attendee scan paths into Ash.

Keep these tests green when building on this slice:

- `test/fastcheck/tickets/issuer_retry_test.exs`
- `test/fastcheck/tickets/issuer_partial_failure_test.exs`
- `test/fastcheck/tickets/issuer_boundary_test.exs`
- `test/fastcheck/tickets/ticket_token_boundary_test.exs`
- `test/fastcheck/tickets/`
- scanner/mobile/Tickera regression tests referenced by VS-09B and VS-09C
- `mix precommit`

## Next Slice

Recommended next slice: **VS-10 — Event Sync Aggregation**

Entry condition:

- VS-09D is merged on `main`.
- `Issuer.issue_order/2` remains the only paid-order issuance entrypoint.
- Issued Sales tickets create scanner-valid Attendees and durable TicketIssue
  rows.
- Retry, partial recovery, manual-review conflict, and audit-context tests stay
  green.
- VS-10 must reuse existing Attendee/mobile sync boundaries and must not
  recreate issuance, delivery, payment, scanner, or Android behavior.
