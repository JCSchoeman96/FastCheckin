# VS-07B Implementation Handoff

## Status

Merged.

PR: #368 — feat(sales): VS-07B Paystack transaction verification  
Merge commit: `0ed9aaf13d93b978c24d23f1f203a9378e233232`  
Merged at: 2026-06-18T15:10:13Z  
Branch: `vs-07b-paystack-transaction-verification`

## What Changed

VS-07B added server-side Paystack transaction verification after webhook
ingestion. `PaystackWebhookWorker` now atomically marks `PaymentEvent` rows
`processing_started` and enqueues `VerifyPaymentWorker`, or `unmatched` when no
local `PaymentAttempt` matches the provider reference. `PaymentVerification`
calls `FastCheck.Payments.Paystack.TransactionVerifier` outside DB transactions,
compares reference/status/amount/currency, and applies named Ash transitions on
`PaymentAttempt`, `Order`, and `CheckoutSession` when preconditions are met.

Review patches included: missing/blank provider reference cannot mark paid;
non-retryable verifier errors finalize to `failed` (not stuck in
`verification_started`); linked events in `processing_started` can move to
`failed`; unexpected webhook lookup errors propagate as `{:error, reason}`.

No webhook controller or `WebhookIngestion` changes. No ticket issuance,
inventory/Redis mutation, scanner/mobile, WhatsApp/Meta, or public verify
endpoint.

## Files Changed

- `lib/fastcheck/sales/payments/payment_verification.ex` — approved Sales
  verification orchestrator; HTTP outside txn; advisory lock on order;
  idempotent `verified_success` short-circuit; match/classify/finalize paths.
- `lib/fastcheck/sales/payments/verify_payment_worker.ex` — Oban worker on
  `:payments`; uniqueness on `payment_attempt_id`; delegates to orchestrator.
- `lib/fastcheck/sales/payments/paystack_webhook_worker.ex` — extended from
  VS-07A shell: `Ecto.Multi` handoff to verify worker or unmatched path;
  explicit lookup error propagation.
- `lib/fastcheck/sales/payment_attempt.ex` — verification Ash actions
  (`mark_verification_started`, `mark_verified_success`, mismatch/failed
  actions, `get_by_provider_reference`); `raw_verify_response` system-only.
- `lib/fastcheck/sales/payment_event.ex` — processing actions
  (`mark_processing_started`, `mark_processed`, `mark_unmatched`, `mark_failed`).
- `lib/fastcheck/sales/order.ex` — `mark_paid_verified` (idempotent).
- `lib/fastcheck/sales/checkout_session.ex` — `mark_paid` (idempotent).
- `lib/fastcheck/payments/paystack/transaction_verifier.ex` — verify
  `safe_data` uses `ResponseSanitizer.drop_sensitive/1`.
- `lib/fastcheck/payments/paystack/response_sanitizer.ex` — `drop_sensitive/1`
  removes sensitive keys entirely for persisted verify snapshots.
- `docs/fastcheck_sales/slices/VS-07B_PAYSTACK_TRANSACTION_VERIFICATION.md` —
  slice summary, boundaries, VS-07C deferrals.
- `test/fastcheck/sales/payments/payment_verification_test.exs` — happy path,
  provider status outcomes, mismatches, expired checkout, retryable timeout,
  missing/blank reference guards, non-retryable verifier errors, log redaction.
- `test/fastcheck/sales/payments/payment_verification_idempotency_test.exs` —
  duplicate verify, already-`verified_success`, worker idempotency.
- `test/fastcheck/sales/payments/payment_verification_security_test.exs` —
  system-only verification transitions; `raw_verify_response` forbidden for
  operator/admin/customer.
- `test/fastcheck/sales/payments/payment_verification_state_test.exs` —
  `StateTransition` rows for verification lifecycle changes.
- `test/fastcheck/sales/payments/payment_verification_boundary_test.exs` —
  module placement under `FastCheck.Sales.Payments.*`; no ticket/inventory/
  scanner coupling in source.
- `test/fastcheck/sales/payments/verify_payment_worker_test.exs` — worker
  enqueue and perform delegation.
- `test/fastcheck/sales/payments/paystack_webhook_worker_test.exs` — atomic
  handoff, unmatched path, missing event error, worker uniqueness.
- `test/support/sales_payments_test_support.ex` — initialized payment fixture,
  verify request stubs, payment event insert helper.
- Updated VS-01C–01G skeleton/boundary/policy tests and
  `test/fastcheck/payments/paystack/webhook_boundary_test.exs` — allow VS-07B
  verification actions and worker behavior.

## Contracts Now Available

- `FastCheck.Sales.Payments.PaymentVerification.verify_attempt/2` — authoritative
  server-side verification entrypoint (optional `payment_event_id` in opts).
- `FastCheck.Sales.Payments.VerifyPaymentWorker` at
  `lib/fastcheck/sales/payments/verify_payment_worker.ex` (not
  `lib/fastcheck/workers/`); args include `payment_attempt_id` and optional
  `payment_event_id`; Oban queue `:payments`; uniqueness on
  `payment_attempt_id`.
- `PaystackWebhookWorker` handoff: matching attempt →
  `processing_started` + verify job; no match → `unmatched`; lookup errors →
  `{:error, reason}`.
- `PaymentAttempt.get_by_provider_reference` — lookup by provider +
  `provider_reference` for webhook handoff.
- Paid transitions when eligible: attempt `verified_success`, order
  `paid_verified`, session `paid` (requires matching Paystack success +
  reference/amount/currency; eligible order/session statuses only).
- Idempotent `verified_success`: skips Paystack re-call; marks linked event
  `processed`; does not mutate order/session when checkout already expired.
- `raw_verify_response` persisted from verifier `safe_data` only (sensitive keys
  dropped); readable by `:system` actor only.
- Telemetry: `[:fastcheck, :sales, :payment, :verified]`, `:mismatch`, `:failed`
  (webhook receive telemetry unchanged from VS-07A).

## Decisions Applied

- Paystack HTTP stays in `FastCheck.Payments.Paystack.*`; Sales orchestration in
  `FastCheck.Sales.Payments.PaymentVerification`.
- Verify HTTP runs outside DB transaction; final writes under
  `pg_advisory_xact_lock(order_id)`.
- Only `data.status == "success"` with matching reference, amount, and currency
  can pay; non-terminal provider statuses are retryable; explicit
  `failed`/`abandoned`/`reversed` are terminal non-paid.
- Nil/missing/blank Paystack `data.reference` → `manual_review`, never paid.
- Non-retryable verifier errors → attempt `failed`, event `failed` when
  `processing_started`.
- Named Ash actions only for state changes; `StateTransition` appended via
  existing resource helpers.
- No new migrations in this slice.
- Integer cents and existing order/attempt amount fields unchanged.

## Boundaries Still Enforced

- No changes to `WebhookIngestion`, Paystack controller, or webhook ingress
  route.
- No `TicketIssue`, `Attendee`, `DeliveryAttempt`, fulfillment queue, or
  inventory/Redis mutation.
- No scanner/mobile API or WhatsApp/Meta integration.
- No admin/customer payment UI or operator manual-review workflows (VS-07C).
- No public HTTP verify endpoint; verification is worker/orchestrator driven
  only.
- No refund, chargeback, or payment-after-expiry inventory policy (VS-07C).

## Tests Added Or Updated

- `test/fastcheck/sales/payments/payment_verification_test.exs` — core verify
  outcomes, reference guards, verifier error finalization, event failure on 401.
- `test/fastcheck/sales/payments/payment_verification_idempotency_test.exs` —
  duplicate execution and verified-success short-circuit.
- `test/fastcheck/sales/payments/payment_verification_security_test.exs` —
  actor/policy boundaries for verification actions and `raw_verify_response`.
- `test/fastcheck/sales/payments/payment_verification_state_test.exs` —
  transition audit rows.
- `test/fastcheck/sales/payments/payment_verification_boundary_test.exs` —
  namespace and forbidden-domain static guards.
- `test/fastcheck/sales/payments/verify_payment_worker_test.exs` — Oban worker
  contract.
- `test/fastcheck/sales/payments/paystack_webhook_worker_test.exs` — webhook
  → verify handoff and error paths.
- VS-01C/F/G skeleton, boundary, and policy tests updated for new actions.
- `test/fastcheck/payments/paystack/webhook_boundary_test.exs` — verification
  no longer forbidden in worker source.

## Verification Reported

From PR #368 test plan and CI on merge head `0ed9aaf`:

```bash
mix test test/fastcheck/sales/payments/payment_verification_*.exs
mix test test/fastcheck/sales/payments/verify_payment_worker_test.exs
mix test test/fastcheck/sales/payments/paystack_webhook_worker_test.exs
mix test test/fastcheck/sales/payments/ test/fastcheck/payments/paystack/
mix test test/fastcheck/sales/vs_01f_policy_test.exs
mix precommit
```

Results reported:

- VS-07B focused verification suites — 28 tests, 0 failures (pre-merge review)
- Sales/payments + paystack regression — 96 tests, 0 failures (pre-merge review)
- `mix precommit` — 672 tests, 0 failures, 4 skipped (pre-merge review)
- GitHub Actions CI run `27768662465` on PR #368 (head `0d5b8b8`) — green
  (compile, format, Credo, Sobelow, DB migrate, full test suite)

## Known Limitations

- Mismatch recovery, operator manual-review resolution, and customer/admin
  surfacing deferred to VS-07C.
- Payment-after-expiry with provider success verifies the attempt only; order/
  session stay unchanged; no inventory restore/accept-late-payment decision.
- Unmatched webhook events stay `unmatched`; no reconciliation playbook yet.
- Duplicate-event policy beyond idempotent terminal states is VS-07C scope.
- No `PaymentEvent` FK to `PaymentAttempt`; linkage is by provider reference
  lookup at worker runtime.
- Staging/production Paystack callback verification smoke not part of merged PR.

## Next Agent Guidance

**Reuse:**

- `FastCheck.Sales.Payments.PaymentVerification` as the sole verify orchestrator.
- `VerifyPaymentWorker` and extended `PaystackWebhookWorker` on `:payments`
  queue under `lib/fastcheck/sales/payments/`.
- `TransactionVerifier` in the provider boundary for Paystack HTTP only.
- `FastCheck.Sales.Payments.TestSupport.initialized_payment!/2`,
  `init_and_verify_request_fun/1`, `insert_payment_event!/1` for payment tests.
- All `test/fastcheck/sales/payments/payment_verification_*` suites as
  authoritative verification boundary tests.

**Do not:**

- Add Paystack HTTP to Ash resources or webhook ingress.
- Create parallel workers under `lib/fastcheck/workers/`.
- Bypass named Ash actions with direct `Repo.update_all` status writes.
- Expose `raw_verify_response` to admin/operator/customer actors.
- Mark orders paid without verified attempt + eligible order/checkout
  preconditions.
- Treat missing/blank provider reference as payable success.
- Implement ticket issuance or inventory mutation in verification paths.

**Keep green:**

- `test/fastcheck/sales/payments/` (initialization + webhook + verification)
- `test/fastcheck/payments/paystack/`
- `test/fastcheck_web/controllers/webhooks/paystack_controller_test.exs`
- `test/fastcheck/sales/vs_01f_policy_test.exs`
- `mix precommit`

## Next Slice

Recommended next slice: **VS-07C — Payment Outcome Handling**

Entry condition:

- VS-07B merged; `PaystackWebhookWorker` → `VerifyPaymentWorker` →
  `PaymentVerification` path is live on `:payments`.
- `PaymentAttempt` supports verification terminal states including
  `manual_review`, mismatches, and `failed`; `PaymentEvent` supports
  `processed`, `unmatched`, and `failed`.
- Orders can reach `paid_verified` and sessions `paid` when checkout is still
  eligible; expired-checkout late payments verify attempt only today.
- VS-07C should build outcome/recovery workflows on top of these states without
  re-implementing ingestion (VS-07A) or verification (VS-07B).
