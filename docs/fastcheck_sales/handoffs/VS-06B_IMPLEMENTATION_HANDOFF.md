# VS-06B Implementation Handoff

## Status

Implemented locally (pending PR).

Branch: `vs-06b-paystack-transaction-initialization`

## What Changed

VS-06B added Sales Paystack transaction initialization with durable pre-HTTP idempotency.

- `FastCheck.Sales.Payments.TransactionInitialization.initialize_for_checkout_session/3`
- `PaymentAttempt` actions: `create_initializing`, `mark_initialized`, `mark_failed`, `mark_manual_review`, `get_active_by_idempotency_key`
- Migration: `initializing` status + `sales_payment_attempts_idempotency_key_active_uidx`
- Config: `:paystack_initializing_stale_after_seconds` (default 120)

## Contracts

- Deterministic idempotency key: `paystack:init:{order_id}:{checkout_session_id}`
- Active index statuses: `initializing`, `initialized` only
- Paystack HTTP only from `TransactionInitialization`; not from Ash resources
- Provider reference sanitized for Paystack charset (underscores in order public refs replaced)

## Tests

- `test/fastcheck/sales/payments/transaction_initialization_test.exs`
- `test/fastcheck/sales/payments/paystack_initialization_idempotency_test.exs`
- `test/fastcheck/sales/payments/paystack_initialization_security_test.exs`
- `test/fastcheck/sales/payment_attempt_initialization_actions_test.exs`

## Verification

- `mix test test/fastcheck/sales/payments/`
- `mix precommit` — 603 tests, 0 failures

## Next slice

VS-06C — Paystack Initialization Tests (hardening)
