# VS-09A Implementation Handoff

## Status

Merged.

PR: #374 — docs(sales): VS-09A ticket issuance contract and idempotency model  
Merge commit: `d5e0b2cc22447d9b36cc342f4de63f83baf6b761`  
Merged at: 2026-06-20T08:17:54Z  
Branch: `vs-09a-ticket-issuance-contract`

## What Changed

VS-09A locked the authoritative ticket issuance contract before any production
code creates Sales-paid Attendees or scanner-valid tickets. The slice added three
contract documents, a mandatory contract-only `FastCheck.Tickets.Issuer` stub,
and contract/boundary tests. Historical Sales boundary tests were narrowed so the
stub is allowed while workers and delivery paths remain forbidden.

No Attendee rows, TicketIssue rows from paid orders, `IssueTicketsWorker`,
migrations, scanner/mobile changes, Paystack changes, or Redis inventory
mutation were added.

## Files Changed

- `docs/fastcheck_sales/VS-09A_ticket_issuance_contract.md` — master issuance
  contract: single `FastCheck.Repo` transaction model, approved entrypoint,
  preconditions, locks, worker boundary, VS-09B/C/D split, blockers.
- `docs/fastcheck_sales/ticket_issuance_failure_matrix.md` — partial failure
  classifications and stable `issuer_*` manual_review reason codes.
- `docs/fastcheck_sales/ticket_issuance_idempotency_keys.md` — deterministic
  issuance units, idempotency keys, DB constraint mapping, VS-09B attendee
  origin unique gap.
- `docs/fastcheck_sales/policies/PARTIAL_TICKET_ISSUANCE_POLICY.md` — cross-links
  to VS-09A contract and failure matrix.
- `lib/fastcheck/tickets/issuer.ex` — contract-only stub; `issue_order/2` raises
  `"not implemented until VS-09B"`.
- `test/fastcheck/tickets/issuer_contract_test.exs` — contract doc presence,
  transaction model, preconditions, slice split.
- `test/fastcheck/tickets/issuer_idempotency_contract_test.exs` — deterministic
  units, constraint mapping, duplicate-worker rules.
- `test/fastcheck/tickets/issuer_boundary_test.exs` — stub is contract-only;
  payment modules still forbid issuance domains; worker path absent.
- `test/fastcheck/tickets/issuer_partial_failure_contract_test.exs` — failure
  matrix recovery paths and reason codes.
- `test/fastcheck/workers/issue_tickets_worker_contract_test.exs` — worker
  contract documented; implementation file still absent.
- `test/fastcheck/tickets/ticket_token_boundary_test.exs` — allows Issuer stub;
  still forbids worker and delivery controller paths.
- `test/fastcheck/sales/core_resource_boundary_test.exs`, `ticket_offer_boundary_test.exs`,
  `vs_01c_boundary_test.exs`, `vs_01d_boundary_test.exs`, `vs_01e_boundary_test.exs`,
  `vs_01f_boundary_test.exs`, `vs_01g_index_and_migration_verification_test.exs` —
  removed `issuer.ex` from historical forbidden-path lists.

## Contracts Now Available

- Authoritative issuance contract at
  `docs/fastcheck_sales/VS-09A_ticket_issuance_contract.md`.
- Failure matrix and idempotency key docs with cross-links to partial issuance
  policy.
- **Selected transaction model:** single `FastCheck.Repo` transaction with
  `pg_advisory_xact_lock(order.id)` (Ash Sales + Ecto Attendees share one repo).
- **Approved entrypoint:** `FastCheck.Tickets.Issuer.issue_order/1|2` (stub exists;
  raises until VS-09B).
- **Approved future caller:** `FastCheck.Workers.IssueTicketsWorker` only (not
  implemented).
- Deterministic issuance unit model: `line_item_sequence = 1..order_line.quantity`;
  recommended origin reference `sales:{order_id}:{line_id}:{sequence}`.
- Documented VS-09B/C/D responsibility split and VS-09B blocker for partial unique
  `attendees(source, source_reference)` where `source = 'fastcheck_sales'`.
- Contract tests guard doc presence, stub boundaries, and payment-path isolation.

## Decisions Applied

- Contract-first before Attendee/TicketIssue creation from paid orders.
- Single-repo transaction preferred over saga (same `FastCheck.Repo` for Ash Sales
  and Ecto Attendees).
- Oban uniqueness is noise reduction only; DB constraints are correctness.
- Issuer must not mutate Redis, call Paystack, or read raw webhook payloads.
- Plaintext QR/delivery tokens remain unpersisted (VS-08 rules referenced).
- `event_scoped_first`; `organization_id` deferred.
- Logging/redaction rules reference VS-21A (`Redactor`, sanitized metadata).

## Boundaries Still Enforced

- No production issuance in `FastCheck.Tickets.Issuer` (stub raises only).
- No Attendee or TicketIssue creation from paid orders.
- No `IssueTicketsWorker` or `:ticketing` Oban queue config.
- No Order fulfillment Ash actions (`ticket_issued`, `partially_issued`, etc.).
- No migrations (attendee origin unique index deferred to VS-09B).
- No scanner/mobile/Android route or sync changes.
- No Paystack/webhook/payment outcome changes.
- No Redis inventory mutation, DeliveryAttempt, WhatsApp/email, or secure ticket
  page.
- No admin manual-review UI.

## Tests Added Or Updated

- `test/fastcheck/tickets/issuer_contract_test.exs` — master contract sections
  and single-transaction model.
- `test/fastcheck/tickets/issuer_idempotency_contract_test.exs` — idempotency doc
  and `:already_issued` rules.
- `test/fastcheck/tickets/issuer_boundary_test.exs` — stub contract-only;
  payment modules lack forbidden issuance terms.
- `test/fastcheck/tickets/issuer_partial_failure_contract_test.exs` — failure
  matrix cases and `issuer_*` reason codes.
- `test/fastcheck/workers/issue_tickets_worker_contract_test.exs` — worker
  contract in docs; file still absent.
- `test/fastcheck/tickets/ticket_token_boundary_test.exs` — Issuer stub allowed;
  worker/delivery paths still forbidden.
- Historical Sales boundary tests — `issuer.ex` removed from forbidden paths.

## Verification Reported

From PR #374 test plan:

```bash
mix test test/fastcheck/tickets/
mix test test/fastcheck/workers/issue_tickets_worker_contract_test.exs
mix test test/fastcheck/sales/payments/
mix precommit
```

Results reported:

- `mix precommit` — 742 tests, 0 failures, 4 skipped

## Known Limitations

- `FastCheck.Tickets.Issuer.issue_order/2` is a stub only; VS-09B implements
  Attendee bridge, VS-09C implements TicketIssue linking.
- No partial unique index on `attendees(source, source_reference)` for Sales origin
  yet (documented VS-09B blocker).
- No Order Ash actions for fulfillment states; no `TicketIssue` create actions.
- `IssueTicketsWorker` and `EventSyncVersionAggregatorWorker` are contract-only.
- No slice doc under `docs/fastcheck_sales/slices/` for VS-09A; contract docs at
  `docs/fastcheck_sales/VS-09A_*` and related paths are authoritative.

## Next Agent Guidance

**Reuse:**

- `docs/fastcheck_sales/VS-09A_ticket_issuance_contract.md` as the active
  issuance contract (not the feature pack alone).
- Failure matrix and idempotency docs for retry/partial-failure behavior.
- Existing VS-08 token/code modules, VS-02 attendee origin fields, VS-07C payment
  preconditions, `StateTransitionSupport.record!/2`, and payment advisory-lock
  pattern.
- Contract tests under `test/fastcheck/tickets/issuer_*` and
  `test/fastcheck/workers/issue_tickets_worker_contract_test.exs`.

**Do not:**

- Recreate parallel issuance orchestration outside `FastCheck.Tickets.Issuer`.
- Issue tickets from payment/webhook/LiveView/WhatsApp paths.
- Implement full `issue_order/2` before reading this handoff and VS-09B pack.
- Add attendee origin unique migration in VS-09B without aligning to documented
  `source_reference` format.
- Bypass documented single-transaction model without an explicit contract revision.

**Keep green:**

- `test/fastcheck/tickets/`
- `test/fastcheck/sales/payments/`
- `test/fastcheck/attendees/origin_protection_test.exs`
- `mix precommit`

## Next Slice

Recommended next slice: **VS-09B — Attendee Creation Bridge**

Entry condition:

- VS-09A merged; contract docs and stub on `main`.
- VS-02 attendee origin protection and VS-08 token primitives remain merged.
- VS-07C payment outcomes can reach `paid_verified` without issuance.
- VS-09B must implement Attendee create/reuse under `Issuer.issue_order/2` per
  contract; must not invent separate issuance rules or create TicketIssue rows.
