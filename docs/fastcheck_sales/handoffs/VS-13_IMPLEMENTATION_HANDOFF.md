# VS-13 Implementation Handoff

## Status

Merged.

PR: #390 — feat(sales): add VS-13 manual review operations  
Merge commit: `31cb999d630925576d3320708e2e5288b80d6975`  
Implementation head: `38a3bd3c0f8b5ea1926847cfc75eeaa7d32c8250`  
Merged at: 2026-06-21T20:25:05Z  
Branch: `vs-13-manual-review-operations`  
CI: run 870 green on implementation head

## What Changed

VS-13 added the first bounded operator workflow for Sales manual-review cases.
An append-only `ManualReviewAction` audit resource records every operator action.
`FastCheck.Sales.ManualReview` is the sole service boundary for queue reads,
context assembly, state transitions, audit writes, and retry job enqueueing.
`FastCheckWeb.SalesManualReviewLive` at `/dashboard/sales/reviews` exposes safe
queue/detail UI under existing dashboard auth and delegates all mutations to
`ManualReview`.

Payment verification retries enqueue `FastCheck.Sales.Payments.VerifyPaymentWorker`
(which delegates to `PaymentVerification`; no inline Paystack calls). Ticket
issuance retries enqueue `FastCheck.Workers.IssueTicketsWorker` (minimal worker
delegating to `FastCheck.Tickets.Issuer.issue_order/2`; no inline attendee or
ticket creation from LiveView).

Named Ash update actions and policies on `Order` and `PaymentAttempt` support
manual-review transitions. PubSub broadcasts on `sales:manual_review` fire only
after successful transaction commits.

No direct LiveView issuance, Paystack calls from LiveView, scanner/mobile
changes, Redis inventory mutation, or delivery/resend/WhatsApp/email behavior
was added.

Planning context (not implementation truth):
`docs/fastcheck_sales/feature_packs/0033_VS-13_manual-review-operations/VS-13-FEATURE_PACK.md`.

## Files Changed

- `priv/repo/migrations/20260621190000_create_manual_review_actions.exs` —
  creates `sales_manual_review_actions`; extends order/payment-attempt status
  enums for manual-review workflow states.
- `lib/fastcheck/sales/manual_review_action.ex` — append-only Ash audit resource;
  `:record_action` create, `:list_for_subject` read; admin/system policies;
  note/reason length validation and `Redactor.safe_metadata/1` on metadata.
- `lib/fastcheck/sales/manual_review.ex` — bounded manual-review service
  boundary; queue merge from orders, payment attempts, and ticket issues;
  context/timeline assembly; operator actions; Oban enqueue; post-commit PubSub.
- `lib/fastcheck/sales/order.ex` — Ash update actions
  `:queue_issuance_retry`, `:hold_manual_review`, `:close_no_fulfillment`,
  `:return_to_fulfillment_queue`, `:return_held_to_manual_review`; admin policies.
- `lib/fastcheck/sales/payment_attempt.ex` — Ash update action
  `:queue_verification_retry`; admin policy.
- `lib/fastcheck/sales.ex` — registers `ManualReviewAction` resource.
- `lib/fastcheck/workers/issue_tickets_worker.ex` — minimal Oban worker on
  `:ticketing` queue; delegates to `Issuer.issue_order/2`; Oban uniqueness on
  `sales_order_id` + `idempotency_key`.
- `lib/fastcheck/sales/payments/verify_payment_worker.ex` — existing worker;
  VS-13 enqueues it from `ManualReview.retry_payment_verification/3` (delegates to
  `PaymentVerification`; no direct Paystack HTTP).
- `lib/fastcheck_web/live/sales_manual_review_live.ex` — dashboard-auth LiveView
  for `/dashboard/sales/reviews`; filter form, queue table, detail panel, and
  bounded action handlers (assign, note, hold, close, return, payment/issuance retry).
- `lib/fastcheck_web/router.ex` — registers
  `live "/dashboard/sales/reviews", SalesManualReviewLive, :index` under
  `[:browser, :dashboard_auth]`.
- `config/config.exs` — adds `:ticketing` Oban queue (concurrency 5).
- `lib/fastcheck/tickets/issuer.ex` — documents `issue_order/2` as issuance
  entrypoint for `IssueTicketsWorker` (no behavioral expansion beyond contract note).
- `test/fastcheck/sales/manual_review_action_test.exs` — audit create/read,
  length validation, metadata redaction.
- `test/fastcheck/sales/manual_review_test.exs` — queue bounds and masking;
  per-source DB cap before merge; context safety; all operator actions; state
  transitions; worker enqueue; fail-closed return guards; sensitive-value scan.
- `test/fastcheck_web/sales_manual_review_live_test.exs` — auth redirect; safe
  queue/detail render; note/payment-retry/close/return submit paths; forbidden
  control absence.
- `test/fastcheck/workers/issue_tickets_worker_test.exs` — uniqueness and
  `Issuer.issue_order/2` delegation.
- `test/fastcheck/workers/issue_tickets_worker_contract_test.exs` — contract
  documents worker presence after VS-13.
- `test/support/sales_boundary_allowlist.ex` — allowlists manual-review modules.
- `test/fastcheck/sales/domain_shell_test.exs`, `vs_01f_boundary_test.exs`,
  `vs_01g_index_and_migration_verification_test.exs`,
  `conversation_resource_migrations_test.exs`, `issuer_boundary_test.exs`,
  `ticket_token_boundary_test.exs` — inventory/boundary index updates only.

## Contracts Now Available

- `FastCheck.Sales.ManualReviewAction` — append-only audit table
  `sales_manual_review_actions`; no update/delete actions.
- `FastCheck.Sales.ManualReview` — authoritative manual-review operations
  entrypoint. Public functions:
  - `list_queue/2` — bounded merged queue (default/max limit 50); optional
    `event_id` filter; safe masked rows for orders, payment attempts, ticket issues.
  - `get_context/3` — `{:ok, context}` or `{:error, reason}` for one subject;
    includes action timeline (`ManualReviewAction` + `StateTransition` summaries).
  - `assign/4`, `unassign/4`, `add_note/4` — audit-only (no status change).
  - `retry_payment_verification/3` — requires `manual_review` payment attempt;
    transitions to `verification_retry_queued`; enqueues `VerifyPaymentWorker`.
  - `retry_ticket_issuance/3` — requires `manual_review` order; transitions to
    `issuance_retry_queued`; enqueues `IssueTicketsWorker`.
  - `hold_for_investigation/3`, `close_no_fulfillment/3`,
    `return_held_to_manual_review/3`, `return_to_fulfillment_queue/3` — bounded
    order state transitions with audit; return is fail-closed on unsafe payment state.
- Route: authenticated `GET /dashboard/sales/reviews` via
  `FastCheckWeb.SalesManualReviewLive`.
- Retry workers (enqueue only from `ManualReview`, not LiveView):
  - `FastCheck.Sales.Payments.VerifyPaymentWorker` — `:payments` queue;
    `PaymentVerification.verify_attempt/2`; Oban uniqueness on `payment_attempt_id`.
  - `FastCheck.Workers.IssueTicketsWorker` — `:ticketing` queue;
    `Issuer.issue_order/2`; Oban uniqueness on `sales_order_id` + `idempotency_key`.
- PubSub topic: `sales:manual_review`, event `{:manual_review_action, payload}`
  after successful commits.
- Queue source statuses:
  - orders: `manual_review`, `manual_review_held`, `issuance_retry_queued`
  - payment attempts: `manual_review`
  - ticket issues: manual-review eligibility per domain query (see tests)
- Buyer/payment/ticket display uses same masking posture as VS-12/VS-21A; raw
  email, phone, Paystack payloads, access codes, authorization URLs, ticket
  codes, token hashes, and idempotency keys are not returned in queue/context HTML.

## Decisions Applied

- All operator mutations flow through `FastCheck.Sales.ManualReview`; LiveView
  handlers do not call Ash, Oban, Paystack, or `Issuer` directly.
- Append-only `ManualReviewAction` for every operator action; state-changing
  actions also use named Ash transitions on `Order` / `PaymentAttempt`.
- Payment retry queues `VerifyPaymentWorker`; issuance retry queues
  `IssueTicketsWorker`; neither worker is invoked inline from the LiveView.
- `IssueTicketsWorker` is minimal: delegates to `Issuer.issue_order/2` only.
- `return_to_fulfillment_queue` is fail-closed unless latest payment attempt is
  `verified_success` and checkout/payment preconditions are safe; blocked
  attempts may still record audit metadata.
- Queue reads apply per-source `order_by`, `limit`, and `sort_id` in the database
  before in-memory merge and final cap (head fix `38a3bd3c`).
- PubSub refresh broadcasts only after transaction commit, not before.
- Extend existing dashboard auth shell (`[:browser, :dashboard_auth]`).
- `event_scoped_first`; `organization_id` deferred.
- VS-12 `AdminDashboard` remains read-only; VS-13 adds sibling operations surface.

## Boundaries Still Enforced

- No direct ticket issuance, attendee creation, or `TicketIssue` writes from
  LiveView or `ManualReview` (issuance retry delegates to `Issuer` via Oban only).
- No Paystack HTTP, webhook handling, or provider payload rendering from LiveView
  or `ManualReview` (verification retry delegates to `VerifyPaymentWorker` →
  `PaymentVerification` only).
- No scanner (`FastCheck.Attendees.Scan`) or mobile sync controller/DTO changes.
- No Android changes.
- No Redis inventory ledger mutation from manual-review paths.
- No delivery, resend, WhatsApp, or email behavior.
- No refund, revoke, mark-paid, release-inventory, or generic admin override console.
- No changes to customer secure ticket page (`GET /t/:token`) behavior.
- VS-12 `/dashboard/sales` dashboard remains read-only visibility only.

## Tests Added Or Updated

- `test/fastcheck/sales/manual_review_action_test.exs` — audit persistence,
  subject listing, validation, redaction.
- `test/fastcheck/sales/manual_review_test.exs` — queue masking and per-source
  DB cap; payment/ticket queue rows; context safety; assign/note audit-only;
  payment retry → `VerifyPaymentWorker`; issuance retry → `IssueTicketsWorker`;
  hold/close/return transitions; unsafe return fail-closed; sensitive-value scan.
- `test/fastcheck_web/sales_manual_review_live_test.exs` — unauthenticated
  redirect; authenticated safe render; note/payment-retry/close/return actions;
  forbidden control text (`mark paid`, `issue ticket`, `refund`, `revoke`,
  `resend`, `delivery`).
- `test/fastcheck/workers/issue_tickets_worker_test.exs` — Oban uniqueness and
  issuer delegation.
- Boundary/shell/index tests updated for new Sales modules and migration.

## Verification Reported

From PR #390 / CI run 870 on head `38a3bd3c0f8b5ea1926847cfc75eeaa7d32c8250`:

```bash
mix format --check-formatted
mix compile --warnings-as-errors
mix test test/fastcheck/sales/manual_review_action_test.exs test/fastcheck/sales/manual_review_test.exs test/fastcheck_web/sales_manual_review_live_test.exs test/fastcheck/workers/issue_tickets_worker_test.exs
mix test test/fastcheck_web/sales/ test/fastcheck/sales/payments/ test/fastcheck/sales/inventory/ test/fastcheck/tickets/ test/fastcheck_web/controllers/mobile/sync_controller_test.exs test/fastcheck/attendees/scan_test.exs test/fastcheck/attendees/reconciliation_test.exs
mix test
mix precommit
```

Results reported at merge:

- targeted manual-review domain + LiveView + worker tests — pass
- broader Sales/payment/inventory/ticket/mobile/attendee regression set — pass
- full `mix test` — pass (0 failures)
- CI run 870 — green

## Known Limitations

- Manual-review scope is bounded to defined actions; no refund/revoke/resend/
  mark-paid/release-inventory workflows (later slices).
- No checkout expiry/cleanup automation (VS-14).
- No delivery or customer notification from manual-review actions.
- Dashboard count cache invalidation on `ManualReviewAction` insert is not wired
  (VS-12 dashboard is snapshot-on-load; operations page reloads queue on action).
- Inventory and payment provider internals remain behind existing service boundaries.
- No dedicated slice doc under `docs/fastcheck_sales/slices/`; feature pack is
  planning context only.

## Next Agent Guidance

**Reuse:**

- `FastCheck.Sales.ManualReview` for all manual-review operator mutations; do
  not add Ash/Oban/Paystack/Issuer calls to LiveViews or controllers.
- `FastCheck.Sales.ManualReviewAction` for audit reads; append via
  `ManualReview` only.
- `FastCheckWeb.SalesManualReviewLive` and route `/dashboard/sales/reviews` for
  operator review workflow UI.
- `VerifyPaymentWorker` and `IssueTicketsWorker` as the only retry enqueue targets
  from manual review; preserve delegation chains.
- `FastCheck.Sales.AdminDashboard` for read-only admin visibility at
  `/dashboard/sales`; do not add destructive controls there.
- Existing masking/redaction patterns from `ManualReview` and VS-21A `Redactor`.

**Do not:**

- Call Paystack, `Issuer.issue_order/2`, or inventory Redis APIs from LiveView.
- Create attendees, ticket issues, or delivery attempts inline from review UI.
- Broaden manual review into a generic admin override or refund console.
- Change scanner/mobile/secure-ticket-page contracts from review work.
- Bypass audit logging for operator actions.

**Keep green:**

- `test/fastcheck/sales/manual_review_action_test.exs`
- `test/fastcheck/sales/manual_review_test.exs`
- `test/fastcheck_web/sales_manual_review_live_test.exs`
- `test/fastcheck/workers/issue_tickets_worker_test.exs`
- `test/fastcheck_web/sales/`
- `test/fastcheck/sales/payments/`
- `test/fastcheck/sales/inventory/`
- `test/fastcheck/tickets/`
- `test/fastcheck_web/controllers/mobile/sync_controller_test.exs`
- `test/fastcheck/attendees/scan_test.exs`
- `test/fastcheck/attendees/reconciliation_test.exs`
- `mix precommit`

## Next Slice

Recommended next slice: **VS-14 — Checkout Expiry and Cleanup**

Entry condition:

- VS-13 is merged on `main`.
- `/dashboard/sales/reviews` and `FastCheck.Sales.ManualReview` own bounded
  manual-review operator workflow with audit and retry enqueue boundaries.
- VS-12 read-only dashboard and VS-07 payment verification / VS-09 issuance
  contracts remain unchanged.
- VS-14 should add automated checkout expiry and hold cleanup without weakening
  manual-review fail-closed guards or introducing delivery/refund behavior.
