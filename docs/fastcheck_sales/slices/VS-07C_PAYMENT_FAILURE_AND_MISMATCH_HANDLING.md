# VS-07C — Payment Failure and Mismatch Handling

## Status

Implemented on branch `vs-07c-payment-failure-mismatch-handling`.

## Summary

Centralized payment outcome classification and application on top of VS-07B verification. After Paystack server-side verify succeeds or fails, Sales routes duplicates, mismatches, provider failures, unmatched webhook events, and late payments after checkout expiry into safe, idempotent, auditable states. Late-payment inventory recovery uses `ReservationLedger` only; no ticket issuance.

## What Changed

- `FastCheck.Sales.Payments.PaymentFailureReason` — stable reason code constants for operators and telemetry
- `FastCheck.Sales.Payments.PaymentOutcomes` — pure classification from verify results + durable local state
- `FastCheck.Sales.Payments.PaymentOutcomeHandler` — Ash transitions, late-payment recovery, telemetry, best-effort PubSub
- `FastCheck.Sales.Payments.OutcomeBroadcast` — sanitized PubSub on approved `TelemetryNames` topics only
- `FastCheck.Sales.Payments.PaymentVerification` — slim orchestrator: HTTP verify → classify → handler inside advisory lock
- `FastCheck.Sales.Payments.PaystackWebhookWorker` — idempotent duplicate/processed short-circuit; `retry_processing` for unmatched events when attempt exists
- Ash actions: `mark_duplicate`, `retry_processing`, `mark_manual_review` (events); `mark_paid_verified_from_late_recovery` (order); `recover_expired_paid_session_to_paid` / `recover_expired_paid_session_to_manual_review` (session)

## Shipped Behavior

- Active checkout success → attempt `verified_success`, order `paid_verified`, session `paid` (unchanged happy path)
- Amount/currency/reference mismatch → dedicated attempt statuses; order and session `manual_review` with stable reason codes
- Provider terminal failure → attempt failed; order unpaid
- Duplicate verified success → idempotent; linked event `processed` (not duplicate) when appropriate
- Expired checkout + provider success → late-payment recovery via `ReservationLedger` (`reserve` + `consume` with compensation on DB failure); success → `paid_verified` / session `paid` without ticket issuance; inventory failure → `manual_review` with `late_payment_inventory_unavailable`
- Unmatched webhook events retained; retry when matching attempt appears later
- Telemetry: `[:fastcheck, :sales, :payment, :verified]`, `:mismatch`, `:failed`, `:manual_review` (approved names only)
- Best-effort PubSub broadcasts for late recovery and duplicate-ignore outcomes (sanitized payloads)

## Boundaries

- No `TicketIssue`, `Attendee`, `IssueTicketsWorker`, scanner/mobile, or WhatsApp flows
- Paystack HTTP remains in `FastCheck.Payments.Paystack.*` only
- Workers remain at `lib/fastcheck/sales/payments/` (not `lib/fastcheck/workers/`)
- No new migrations
- No public verify endpoint changes

## Key Files

- `lib/fastcheck/sales/payments/payment_failure_reason.ex`
- `lib/fastcheck/sales/payments/payment_outcomes.ex`
- `lib/fastcheck/sales/payments/payment_outcome_handler.ex`
- `lib/fastcheck/sales/payments/outcome_broadcast.ex`
- `lib/fastcheck/sales/payments/payment_verification.ex`
- `lib/fastcheck/sales/payments/paystack_webhook_worker.ex`
- `test/fastcheck/sales/payments/payment_outcomes_test.exs`
- `test/fastcheck/sales/payments/payment_failure_and_mismatch_test.exs`
- `test/fastcheck/sales/payments/payment_after_expiry_test.exs`
- `test/fastcheck/sales/payments/payment_duplicate_idempotency_test.exs`
- `test/fastcheck/sales/payments/payment_unmatched_event_test.exs`
- `test/fastcheck/sales/payments/payment_boundary_test.exs`
- `test/fastcheck/sales/payments/payment_policy_test.exs`
- `test/fastcheck/sales/payments/payment_security_test.exs`

## Deferred (Not Implemented Here)

- Operator manual-review resolution UI and admin payment dashboard (VS-12 / VS-21B)
- Ticket issuance after paid verification (VS-09A)
- Customer notifications for failed/mismatch payments
- Automated checkout expiry worker (VS-14)
- Refund and chargeback handling

## Next Slice

VS-09A — Ticket issuance idempotency after `paid_verified`, or VS-12 support/payment status surfacing for `manual_review` outcomes.
