# VS-07B — Paystack Transaction Verification

## Status

Implemented on branch `vs-07b-paystack-transaction-verification`.

## Summary

Server-side Paystack transaction verification wired from webhook ingestion through Sales orchestration and Oban workers. Verification confirms provider reference, status, amount, and currency against a local `PaymentAttempt`, then marks order and checkout session paid when preconditions are met.

## What Changed

- `FastCheck.Sales.Payments.PaymentVerification` — orchestrator with HTTP-outside-DB flow, advisory lock on order, idempotent `verified_success` short-circuit
- `FastCheck.Sales.Payments.VerifyPaymentWorker` — Oban worker on `:payments` queue with uniqueness on `payment_attempt_id`
- `FastCheck.Sales.Payments.PaystackWebhookWorker` — atomic `Ecto.Multi` handoff: mark event `processing_started` + enqueue verify, or `unmatched` without verify job
- Ash actions on `PaymentAttempt`, `PaymentEvent`, `Order`, `CheckoutSession` for verification lifecycle transitions
- `raw_verify_response` field policy restricted to system-only; persistence uses `ResponseSanitizer.drop_sensitive/1` (no PII keys stored)
- `FastCheck.Payments.Paystack.ResponseSanitizer.drop_sensitive/1` for verify snapshot persistence

## Shipped Behavior

- Provider `data.status == "success"` with matching reference, amount, and currency → `verified_success`, order `paid_verified`, session `paid` when checkout still eligible
- Non-terminal provider statuses (`pending`, `ongoing`, etc.) → retryable; order stays unpaid
- Explicit provider failures (`failed`, `abandoned`) → attempt terminal failure; order unpaid
- Amount/currency mismatch → dedicated mismatch statuses; order unpaid
- Already `verified_success` → skip Paystack call; mark linked event `processed`; no order/session mutation for expired checkout
- Expired/released checkout with provider success → attempt verified only; order and session unchanged
- `StateTransition` rows appended for each state change
- Telemetry: `[:fastcheck, :sales, :payment, :verified]`, `:mismatch`, `:failed`

## Boundaries

- No changes to webhook controller or `WebhookIngestion`
- No Paystack HTTP inside Ash resource modules
- No `TicketIssue`, `Attendee`, inventory/Redis, scanner, WhatsApp, or refund flows
- No public verify endpoint; verification is worker-driven only

## Key Files

- `lib/fastcheck/sales/payments/payment_verification.ex`
- `lib/fastcheck/sales/payments/verify_payment_worker.ex`
- `lib/fastcheck/sales/payments/paystack_webhook_worker.ex`
- `lib/fastcheck/payments/paystack/transaction_verifier.ex`
- `lib/fastcheck/payments/paystack/response_sanitizer.ex`
- `lib/fastcheck/sales/payment_attempt.ex`
- `lib/fastcheck/sales/payment_event.ex`
- `test/fastcheck/sales/payments/payment_verification_*.exs`
- `test/fastcheck/sales/payments/verify_payment_worker_test.exs`

## Deferred to VS-07C (Not Implemented Here)

- Mismatch recovery workflows and operator manual-review resolution
- Duplicate-event policy beyond idempotent terminal states
- Payment-after-expiry inventory decisions (whether to restore holds or accept late payment)
- Unmatched webhook retry / reconciliation playbooks
- Reference mismatch → `manual_review` outcome handling beyond safe classification
- Customer notification or admin dashboard surfacing for failed/mismatch attempts

## Next Slice

VS-07C — Payment Outcome Handling (mismatch recovery, late payment, duplicate events)
