# VS-09C Implementation Handoff

## Status

Merged.

PR: #378 — VS-09C TicketIssue audit linking  
Merge commit: `bf2f96cc56699c1571a07f519a19e8f014783ed3`  
Merged at: 2026-06-20T15:41:52Z  
Branch: `vs-09c-ticketissue-audit-linking`

## What Changed

VS-09C extended `FastCheck.Tickets.Issuer.issue_order/2` past VS-09B attendee
readiness. A paid verified Sales order now creates or reuses one
`FastCheck.Sales.TicketIssue` row per deterministic order-line unit, links it to
the existing Sales-created `Attendee`, back-links
`attendees.sales_ticket_issue_id`, and marks the order `ticket_issued` only after
all expected issue rows exist.

The slice stores only ticket QR and delivery token hashes, records
`TicketIssue` and `Order` state transitions, and keeps duplicate/retry/concurrent
issuance idempotent. It did not add delivery, workers, payment, Redis, scanner,
mobile, Android, WhatsApp, or handoff-doc behavior in the implementation PR.

## Files Changed

- `lib/fastcheck/tickets/issuer.ex` — owns the VS-09B attendee reuse plus VS-09C
  TicketIssue linking, attendee backlinking, final order transition, and
  manual-review conflict handling.
- `lib/fastcheck/sales/ticket_issue.ex` — adds narrow Ash actions
  `get_by_order_line_sequence` and `create_issued_link`, including safe
  `TicketIssue` StateTransition audit metadata.
- `lib/fastcheck/sales/order.ex` — adds the named `mark_ticket_issued` transition
  action.
- `test/fastcheck/tickets/issuer_ticket_issue_linking_test.exs` — proves
  successful linking, token-hash-only persistence, order finalization,
  StateTransition metadata, and no `DeliveryAttempt` rows.
- `test/fastcheck/tickets/issuer_idempotency_test.exs` — proves retry,
  concurrency, missing issue recovery, and conflict/manual-review behavior.
- `test/fastcheck/sales/ticket_issue_test.exs` — proves `create_issued_link`
  writes safe `TicketIssue` StateTransition metadata.
- `test/fastcheck/tickets/issuer_boundary_test.exs` and
  `test/fastcheck/tickets/ticket_token_boundary_test.exs` — keep forbidden worker,
  delivery, payment, Redis, scanner, mobile, and Android paths out of issuance.
- `test/fastcheck/sales/*resource_skeletons_test.exs` — updates action skeleton
  expectations for the new narrow TicketIssue and Order actions.
- `test/fastcheck/tickets/issuer_attendee_bridge_test.exs` — updates VS-09B
  expectations now that successful issuance creates TicketIssue rows.

## Contracts Now Available

- `FastCheck.Tickets.Issuer.issue_order/2` is the authoritative paid-order
  issuance entrypoint through attendee creation/reuse, TicketIssue audit linking,
  attendee backlinking, and order finalization.
- Successful fresh issuance returns `status: :ticket_issued`; full idempotent
  retry returns `status: :already_issued`.
- Returned issue summaries include `id`, `attendee_id`, and `source_reference`;
  plaintext QR or delivery tokens are not returned.
- `FastCheck.Sales.TicketIssue.create_issued_link` creates issued, scanner-valid
  TicketIssue rows through Ash and writes a `TicketIssue` StateTransition.
- `FastCheck.Sales.TicketIssue.get_by_order_line_sequence` is available for
  deterministic lookup by `sales_order_line_id + line_item_sequence`.
- `FastCheck.Sales.Order.mark_ticket_issued` transitions orders to
  `ticket_issued` and writes the existing Order StateTransition audit.
- Existing DB identities on `sales_ticket_issues` remain the correctness guard
  for ticket code, order-line sequence, attendee ID, QR hash, and delivery hash.
- `attendees.sales_ticket_issue_id` is now populated for Sales-issued tickets.

## Decisions Applied

- Reuse the VS-09B attendee bridge; do not recreate attendees.
- Use deterministic `sales:{order_id}:{order_line_id}:{sequence}` source
  references and `sales_order_line_id + line_item_sequence` issue identity.
- Create TicketIssue rows directly as `status = "issued"` and
  `scanner_status = "valid"` after attendee validation.
- Store only `qr_token_hash`, `delivery_token_hash`, and
  `delivery_token_expires_at`; never persist or return plaintext tokens.
- Keep StateTransition metadata safe: no ticket code, token plaintext, token
  hashes, buyer PII, or raw provider payloads.
- Prefer rollback/retry for transient failures and manual review for deterministic
  unsafe conflicts.
- Keep scanner/mobile runtime behavior on existing Attendee fields and routes.

## Boundaries Still Enforced

- No `DeliveryAttempt` rows are created.
- No `IssueTicketsWorker` implementation or Oban queue config was added.
- No Paystack, webhook, checkout, or payment verification behavior changed.
- No Redis inventory mutation.
- No WhatsApp, Meta, email, or secure ticket page delivery.
- No scanner route, mobile controller, Android DTO, or Android app changes.
- No event sync version aggregator; VS-10 owns scanner-visible sync aggregation.
- No admin/customer UI and no manual-review operations UI.
- No implementation handoff docs were included in PR #378.

## Tests Added Or Updated

- `test/fastcheck/tickets/issuer_ticket_issue_linking_test.exs` — happy path,
  ticket issue fields, attendee backlinks, token-hash-only storage, order
  `ticket_issued`, audit rows, and no delivery attempts.
- `test/fastcheck/tickets/issuer_idempotency_test.exs` — second-call reuse,
  concurrent calls, matching existing TicketIssue reuse, missing issue recovery,
  mismatched TicketIssue conflict, and conflicting attendee backlink conflict.
- `test/fastcheck/sales/ticket_issue_test.exs` — resource-level
  `create_issued_link` StateTransition metadata coverage.
- `test/fastcheck/tickets/issuer_boundary_test.exs` — issuer may reference
  TicketIssue/token helpers but still must not reference worker, delivery,
  payment, Redis, scanner, mobile, or Android paths.
- `test/fastcheck/tickets/ticket_token_boundary_test.exs` — token boundary now
  allows TicketIssue linking while still forbidding delivery behavior.
- Existing VS-09B attendee bridge tests were updated for the new final
  ticket-issue outcome.

## Verification Reported

From PR #378 body:

```bash
mix test test/fastcheck/tickets/
mix test test/fastcheck/sales/ticket_and_delivery_resource_skeletons_test.exs test/fastcheck/sales/core_resource_skeletons_test.exs test/fastcheck/sales/vs_01f_policy_test.exs test/fastcheck/sales/vs_01g_index_and_migration_verification_test.exs test/fastcheck/attendees/origin_protection_test.exs test/fastcheck/attendees/reconciliation_test.exs test/fastcheck/attendees/scan_test.exs test/fastcheck_web/controllers/mobile/sync_controller_test.exs
mix compile --warnings-as-errors
mix test
mix precommit
```

Additional review-patch verification before merge:

- `mix test test/fastcheck/sales/ticket_issue_test.exs test/fastcheck/tickets/issuer_ticket_issue_linking_test.exs test/fastcheck/tickets/issuer_idempotency_test.exs`
  — 8 tests, 0 failures
- `mix test test/fastcheck/tickets/` — 63 tests, 0 failures
- `mix precommit` — 762 tests, 0 failures, 4 skipped
- GitHub Actions for PR #378 reported success before merge.

## Known Limitations

- `IssueTicketsWorker` remains absent; no background issuance queue exists yet.
- Partial-failure hardening beyond the VS-09C idempotency cases belongs to
  VS-09D.
- `Order.mark_partially_issued` was not added.
- Delivery history remains absent; `DeliveryAttempt` is still later-slice work.
- Secure ticket page, QR display, resend, WhatsApp/email delivery, and delivery
  window handling remain deferred.
- Scanner/mobile sync aggregation for issued Sales tickets remains VS-10 work.
- Revocation/refund scanner denial remains VS-15A work.

## Next Agent Guidance

Reuse `FastCheck.Tickets.Issuer.issue_order/2`; do not create another issuance
entrypoint. Reuse existing attendees, `source_reference`, `sales_ticket_issue_id`,
`TicketIssue.create_issued_link`, `TicketIssue.get_by_order_line_sequence`,
`Order.mark_ticket_issued`, and VS-08 token helpers.

Do not bypass the issuer from Paystack webhooks, WhatsApp, controllers, LiveViews,
or workers. Do not recreate token hashing, store plaintext customer-facing
tokens, or place ticket codes/token hashes/customer PII in StateTransition
metadata. Do not move scanner, mobile sync, Tickera reconciliation, or Attendee
runtime paths into Ash.

Keep these tests green when building on this slice:

- `test/fastcheck/tickets/issuer_ticket_issue_linking_test.exs`
- `test/fastcheck/tickets/issuer_idempotency_test.exs`
- `test/fastcheck/sales/ticket_issue_test.exs`
- `test/fastcheck/tickets/issuer_boundary_test.exs`
- `test/fastcheck/tickets/ticket_token_boundary_test.exs`
- `test/fastcheck/tickets/`
- scanner/mobile/Tickera regression tests touched by VS-09B
- `mix precommit`

## Next Slice

Recommended next slice: **VS-09D — Issuance Retry and Partial Failure Tests**

Entry condition:

- VS-09C is merged on `main`.
- `Issuer.issue_order/2` can create/reuse Attendees and TicketIssues and return
  `:ticket_issued` or `:already_issued`.
- `TicketIssue.create_issued_link` and `Order.mark_ticket_issued` audits remain
  mandatory and safe.
- VS-09D should primarily add retry/partial-failure tests and only make minimal
  `FastCheck.Tickets.Issuer` fixes required by those tests.
