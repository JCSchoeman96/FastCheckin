# VS-07C Implementation Handoff

## Status

Merged.

PR: #370 — feat(sales): VS-07C payment failure and mismatch handling  
Merge commit: `3123071f3f0da488cb0eb29eb954ebf463052a47`  
Merged at: 2026-06-18T18:20:10Z  
Branch: `vs-07c-payment-failure-mismatch-handling`

## What Changed

VS-07C added a centralized payment outcome layer on top of merged VS-07B
verification. `PaymentVerification` still owns the verify entrypoint and advisory
lock, but now classifies post-verify results via `PaymentOutcomes` and applies
safe transitions via `PaymentOutcomeHandler`.

Mismatches move order and checkout session into `manual_review` with stable reason
codes. Expired checkout with a verified Paystack success attempts late-payment
inventory recovery through `LatePaymentRecovery` (`reserve` → Postgres paid
transitions → `consume`) with hold release on DB failure and
`reconciliation_required` marking when consume fails after pay. Recovery success
reaches `paid_verified` / session `paid` without ticket issuance.

Duplicate payments on already-settled orders mark the second `PaymentAttempt`
`duplicate`. `PaystackWebhookWorker` short-circuits `duplicate`/`processed`
events and can `retry_processing` for previously `unmatched` events when a
matching attempt appears.

No webhook controller changes. No ticket issuance, attendee mutation,
scanner/mobile, or WhatsApp flows. No new migrations.

## Files Changed

- `lib/fastcheck/sales/payments/payment_failure_reason.ex` — stable reason code
  constants for manual review, mismatches, and late-payment outcomes.
- `lib/fastcheck/sales/payments/payment_outcomes.ex` — pure post-verify
  classification; no Ash, Paystack HTTP, or Redis.
- `lib/fastcheck/sales/payments/payment_outcome_handler.ex` — applies classified
  outcomes through named Ash actions, telemetry, and best-effort PubSub.
- `lib/fastcheck/sales/payments/late_payment_recovery.ex` — compensation-safe
  late-payment inventory sequence (reserve → paid → consume).
- `lib/fastcheck/sales/payments/outcome_broadcast.ex` — sanitized, best-effort
  PubSub on approved topics only.
- `lib/fastcheck/sales/payments/payment_verification.ex` — slim orchestrator;
  delegates classify/apply to outcome layer inside existing advisory lock.
- `lib/fastcheck/sales/payments/paystack_webhook_worker.ex` — duplicate/processed
  idempotency; `retry_processing` for unmatched events when attempt exists.
- `lib/fastcheck/sales/payment_attempt.ex` — `mark_duplicate`.
- `lib/fastcheck/sales/payment_event.ex` — `mark_duplicate`, `retry_processing`,
  `mark_manual_review`.
- `lib/fastcheck/sales/order.ex` — `mark_paid_verified_from_late_recovery`.
- `lib/fastcheck/sales/checkout_session.ex` —
  `recover_expired_paid_session_to_paid`,
  `recover_expired_paid_session_to_manual_review`.
- `docs/fastcheck_sales/slices/VS-07C_PAYMENT_FAILURE_AND_MISMATCH_HANDLING.md`
  — slice summary and deferred scope (not a handoff substitute).
- `test/fastcheck/sales/payments/payment_outcomes_test.exs` — pure classifier
  unit tests.
- `test/fastcheck/sales/payments/late_payment_recovery_test.exs` — reserve
  release on DB failure; reconciliation when consume fails after pay.
- `test/fastcheck/sales/payments/payment_after_expiry_test.exs` — late payment
  with unavailable inventory → manual review.
- `test/fastcheck/sales/payments/payment_duplicate_idempotency_test.exs` —
  idempotent re-verify and second attempt on paid order → `duplicate`.
- `test/fastcheck/sales/payments/payment_failure_and_mismatch_test.exs` —
  mismatch/manual-review integration paths.
- `test/fastcheck/sales/payments/payment_unmatched_event_test.exs` — unmatched
  event retention and retry when attempt matches.
- `test/fastcheck/sales/payments/payment_boundary_test.exs` — no ticket/attendee/
  WhatsApp coupling in outcome modules.
- `test/fastcheck/sales/payments/payment_policy_test.exs` — customer_session
  cannot run verification transitions.
- `test/fastcheck/sales/payments/payment_security_test.exs` — outcome log
  redaction.
- `test/fastcheck/sales/payments/payment_verification_test.exs` — updated for
  mismatch → manual review and late-payment recovery when inventory allows.
- `test/fastcheck/sales/payments/payment_verification_idempotency_test.exs` —
  updated expired-checkout idempotency expectations after late recovery.
- `test/support/sales_payments_test_support.ex` — `insert_initialized_attempt!/2`
  for duplicate-attempt tests.
- Updated VS-01C skeleton/boundary tests for promoted duplicate/retry actions.

## Contracts Now Available

- `FastCheck.Sales.Payments.PaymentOutcomes.classify_provider_result/4` —
  deterministic outcome + attrs from verify result and durable local state.
- `FastCheck.Sales.Payments.PaymentOutcomeHandler.apply/7` and
  `apply_idempotent_verified/5` — authoritative outcome application inside the
  caller's advisory-locked transaction.
- `FastCheck.Sales.Payments.PaymentFailureReason.*` — stable operator-facing
  codes (`payment_amount_mismatch`, `payment_reference_mismatch`,
  `late_payment_inventory_unavailable`, `payment_duplicate_suspicious`, etc.).
- `FastCheck.Sales.Payments.LatePaymentRecovery.recover/2` — late-payment
  inventory recovery with idempotency keys
  `late_recovery:reserve|consume|release:<payment_attempt_id>`.
- Mismatch paths: order/session `manual_review` with `manual_review_reason` set;
  attempt gets dedicated mismatch or manual-review statuses.
- Late-payment success: order `paid_verified`, session `paid` (no tickets).
- Second payment on `paid_verified` order: attempt `duplicate`; no order/session
  or inventory mutation.
- `PaystackWebhookWorker`: `duplicate`/`processed` events are no-ops;
  `unmatched` events can `retry_processing` when attempt later exists.
- Telemetry: existing `[:fastcheck, :sales, :payment, :verified|:mismatch|:failed]`
  plus `[:fastcheck, :sales, :manual_review, :opened]` on manual-review paths.
- Best-effort PubSub via `OutcomeBroadcast` (sanitized payloads only).

## Decisions Applied

- Outcome modules live under `FastCheck.Sales.Payments.*`, not
  `FastCheck.Payments.Paystack.*`.
- `PaymentVerification` remains the single verify entrypoint; no parallel outcome
  orchestrator.
- Classification is pure; mutation happens only in `PaymentOutcomeHandler` via
  named Ash actions.
- Late-payment recovery uses `ReservationLedger` public API only (no direct Redis
  key mutation in Sales payment code).
- Late recovery order is **reserve → Postgres paid → consume**, with hold
  release on DB failure and ledger `reconciliation_required` when consume fails
  after pay.
- Integer cents and existing amount fields unchanged; no new migrations.
- No ticket issuance even when late recovery succeeds.
- Workers remain at `lib/fastcheck/sales/payments/` (not `lib/fastcheck/workers/`).

## Boundaries Still Enforced

- No `TicketIssue`, `Attendee`, `IssueTicketsWorker`, `DeliveryAttempt`, or
  fulfillment queue.
- No scanner/mobile API changes.
- No WhatsApp/Meta integration.
- No Paystack HTTP inside Ash resources or outcome modules.
- No webhook controller or `WebhookIngestion` changes.
- No operator manual-review resolution UI or admin payment dashboard (VS-12 /
  VS-21B).
- No customer notifications for failed/mismatch payments.
- No automated checkout expiry worker (VS-14).
- No refund or chargeback handling.
- No public HTTP verify endpoint.

## Tests Added Or Updated

- `test/fastcheck/sales/payments/payment_outcomes_test.exs` — classifier outcomes
  for active checkout, mismatches, expired session, retryable pending.
- `test/fastcheck/sales/payments/late_payment_recovery_test.exs` — compensation
  and reconciliation markers.
- `test/fastcheck/sales/payments/payment_after_expiry_test.exs` — inventory
  unavailable late payment → manual review.
- `test/fastcheck/sales/payments/payment_duplicate_idempotency_test.exs` —
  idempotent re-verify and duplicate second attempt.
- `test/fastcheck/sales/payments/payment_failure_and_mismatch_test.exs` —
  end-to-end mismatch handling.
- `test/fastcheck/sales/payments/payment_unmatched_event_test.exs` — unmatched
  retention and retry handoff.
- `test/fastcheck/sales/payments/payment_boundary_test.exs` — forbidden domain
  static guards and module placement.
- `test/fastcheck/sales/payments/payment_policy_test.exs` — Ash policy on
  verification transitions.
- `test/fastcheck/sales/payments/payment_security_test.exs` — log redaction on
  mismatch outcomes.
- Updated `payment_verification_test.exs` and
  `payment_verification_idempotency_test.exs` for VS-07C behavior.
- VS-07B verification, webhook, worker, and paystack suites remain authoritative
  regression coverage for the full payment stack.

## Verification Reported

From PR #370 test plan and CI on merge head `3123071`:

```bash
mix test test/fastcheck/sales/payments/
mix test test/fastcheck/payments/paystack/
mix test test/fastcheck/sales/vs_01f_policy_test.exs
mix precommit
```

Results reported:

- Sales/payments suite — green (PR #370 test plan)
- Paystack regression — green (PR #370 test plan)
- `mix precommit` — 690 tests, 0 failures, 4 skipped (final local gate before merge)
- GitHub Actions CI run `27777088571` on PR #370 (head `dd15209`) — **pass**
  (Elixir 1.17.3 / OTP 26.2, ~2m8s)

## Known Limitations

- Operator resolution workflows for `manual_review` payments deferred to VS-12.
- Ticket issuance after `paid_verified` deferred to VS-09A.
- Admin payment dashboard / PubSub consumer surfacing deferred to VS-21B.
- Customer notifications for failed/mismatch/duplicate payments not implemented.
- Automated checkout expiry and hold cleanup deferred to VS-14.
- No refund/chargeback flows.
- `PaymentEvent` still has no FK to `PaymentAttempt`; linkage is by provider
  reference at worker runtime.
- PubSub broadcasts are best-effort; do not rely on them for critical workflows
  until dashboard cache exists.

## Next Agent Guidance

**Reuse:**

- `PaymentVerification` → `PaymentOutcomes` → `PaymentOutcomeHandler` as the
  sole post-verify pipeline.
- `LatePaymentRecovery` for any late-payment inventory work; do not reimplement
  reserve/consume sequencing inline.
- `PaymentFailureReason` constants for manual-review reason codes and telemetry.
- `FastCheck.Sales.Payments.TestSupport.initialized_payment!/2`,
  `insert_initialized_attempt!/2`, and existing paystack request stubs.
- All `test/fastcheck/sales/payments/` suites as authoritative payment boundary
  tests.

**Do not:**

- Fork a second verification or outcome orchestrator.
- Add Paystack HTTP to outcome/handler modules.
- Mutate Redis inventory keys directly from payment code (use `ReservationLedger`).
- Issue tickets or create `Attendee` rows from payment outcome paths.
- Bypass named Ash actions with direct status writes.
- Mark orders paid without going through the outcome layer.
- Recreate VS-07B verification logic inside later slices.

**Keep green:**

- `test/fastcheck/sales/payments/`
- `test/fastcheck/payments/paystack/`
- `test/fastcheck/sales/vs_01f_policy_test.exs`
- `mix precommit`

## Next Slice

Recommended next slice: **VS-09A — Ticket Issuance Idempotency**

Entry condition:

- VS-07C merged; orders can reach `paid_verified` and sessions `paid` through
  active checkout or late-payment recovery.
- Mismatch and late-payment manual-review outcomes are encoded with stable reason
  codes; payment outcome tests are green.
- VS-09A should issue tickets idempotently from `paid_verified` without
  re-implementing Paystack verification (VS-07B) or outcome handling (VS-07C).

Alternative near-term slice: **VS-12 — Manual Review Operations** for operator
workflows on `manual_review` orders/payments surfaced by VS-07C.
