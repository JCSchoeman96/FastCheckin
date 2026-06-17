# VS-06B — Paystack Transaction Initialization

## Summary

VS-06B connects valid Sales checkout sessions to the VS-06A Paystack provider boundary.
The approved entrypoint is `FastCheck.Sales.Payments.TransactionInitialization.initialize_for_checkout_session/3`.

## Shipped behavior

- Validates order, checkout session, hold, buyer email, and amount snapshots before Paystack.
- Creates a durable `PaymentAttempt` in `initializing` status under `pg_advisory_xact_lock` before HTTP.
- Calls `FastCheck.Payments.Paystack.TransactionInitializer` outside DB transactions.
- Marks attempts `initialized` on success; `failed` or `manual_review` on provider/stale errors.
- Idempotent replay for `initialized` attempts; `:payment_initialization_in_progress` for recent `initializing`.
- Stale `initializing` rows (default 120s) move to `manual_review` with `stale_initialization`.
- `CheckoutSession.mark_payment_link_sent` only from `hold_attached`.

## Not in scope (deferred)

- Webhooks, verification, `PaymentEvent`, paid order transitions, ticketing, inventory mutation, WhatsApp/scanner/mobile.

## Key files

- `lib/fastcheck/sales/payments/transaction_initialization.ex`
- `lib/fastcheck/sales/payment_attempt.ex`
- `priv/repo/migrations/20260617120000_add_payment_attempt_initializing_and_active_idempotency.exs`
- `test/fastcheck/sales/payments/*`
