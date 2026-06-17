# VS-06B Implementation Handoff

## Status

Merged.

PR: #362 — feat(sales): VS-06B Paystack transaction initialization  
Merge commit: `9928a89739392cd81be648d636dd9028b2665aae`  
Merged at: 2026-06-17T16:00:52Z  
Branch: `vs-06b-paystack-transaction-initialization`

## What Changed

VS-06B connected valid Sales checkout sessions to the VS-06A Paystack provider
boundary through a single Sales orchestrator. It added durable pre-HTTP
`PaymentAttempt` idempotency (`initializing` → `initialized` / `failed` /
`manual_review`), advisory locking per order, stale-initializing TTL handling,
active-status idempotency uniqueness, and checkout-session
`payment_link_sent` transition on first success.

Expired `payment_link_sent` sessions no longer replay stored authorization URLs.

## Files Changed

- `lib/fastcheck/sales/payments/transaction_initialization.ex` — approved Sales
  entrypoint `initialize_for_checkout_session/3`; validation, lock, Paystack
  call, and session transition orchestration.
- `lib/fastcheck/sales/payment_attempt.ex` — workflow actions
  `create_initializing`, `mark_initialized`, `mark_failed`, `mark_manual_review`,
  `get_active_by_idempotency_key`; policies and transition hooks.
- `priv/repo/migrations/20260617120000_add_payment_attempt_initializing_and_active_idempotency.exs`
  — adds `initializing` status and partial unique index
  `sales_payment_attempts_idempotency_key_active_uidx`.
- `config/config.exs` — default `:paystack_initializing_stale_after_seconds`
  (120).
- `config/runtime.exs` — `PAYSTACK_INITIALIZING_STALE_AFTER_SECONDS` override.
- `docs/fastcheck_sales/slices/VS-06B_PAYSTACK_TRANSACTION_INITIALIZATION.md`
  — slice summary and deferred scope.
- `test/support/sales_payments_test_support.ex` — Paystack test env setup and
  checkout fixtures for payment init tests.
- `test/fastcheck/sales/payments/transaction_initialization_test.exs` — valid
  init, validation failures, stale initializing, expired replay, log redaction.
- `test/fastcheck/sales/payments/paystack_initialization_idempotency_test.exs`
  — replay, concurrency, in-progress initializing, failed-row retry.
- `test/fastcheck/sales/payments/paystack_initialization_security_test.exs` —
  actor scoping and forbidden operator access.
- `test/fastcheck/sales/payment_attempt_initialization_actions_test.exs` — Ash
  action transitions for initialization workflow.
- `test/fastcheck/sales/checkout_and_payment_resource_migrations_test.exs` —
  migration/index assertions for `initializing` and active idempotency index.
- `test/fastcheck/sales/checkout_and_payment_resource_skeletons_test.exs` —
  allows VS-06B `PaymentAttempt` actions.
- `test/fastcheck/sales/vs_01f_boundary_test.exs` — allows VS-06B actions;
  verification/webhook paths remain forbidden.

## Contracts Now Available

- `FastCheck.Sales.Payments.TransactionInitialization.initialize_for_checkout_session/3`
  is the sole approved Sales Paystack initialization API.
- Deterministic idempotency key:
  `paystack:init:{order_id}:{checkout_session_id}`.
- `sales_payment_attempts` accepts `initializing` status; partial unique index
  `sales_payment_attempts_idempotency_key_active_uidx` enforces one active row per
  idempotency key for `initializing` and `initialized` only.
- Durable `initializing` row is created under `pg_advisory_xact_lock(order_id)`
  before Paystack HTTP; HTTP runs outside the DB transaction.
- Idempotent replay returns existing `initialized` attempt; recent
  `initializing` returns `:payment_initialization_in_progress`; stale
  `initializing` (default ≥120s) moves to `manual_review` with
  `stale_initialization`.
- `CheckoutSession.mark_payment_link_sent` runs only when session status is
  `hold_attached`; `payment_link_sent` replay requires non-expired session.
- Checkout actors allowed: `:system`, `:admin`, `:customer_session` (operators
  forbidden).
- Paystack calls go through `FastCheck.Payments.Paystack.TransactionInitializer`
  from the orchestrator only.

## Decisions Applied

- Durable pre-HTTP idempotency row (not advisory-lock-only).
- Active-status partial unique index — `failed` / `manual_review` rows do not
  block retry.
- Stale `initializing` TTL default 120s (`:paystack_initializing_stale_after_seconds`).
- Single orchestrator API; no parallel initialization paths.
- Provider reference sanitized for Paystack charset (`_` in order public refs
  replaced).
- `StateTransitionSupport` unchanged; workflow encoded in `PaymentAttempt`
  actions and orchestrator.
- Integer cents for amounts; no new money fields beyond existing order/attempt
  snapshots.

## Boundaries Still Enforced

- No Paystack webhooks or webhook routes.
- No payment verification (`TransactionVerifier`) or `PaymentEvent` persistence.
- No paid-order transitions, ticket issuance, or inventory mutation.
- No WhatsApp, scanner, mobile API, or admin/customer UI wiring.
- No direct Paystack HTTP from Ash resources, LiveViews, or camera/queue paths.
- No checkout workflow changes beyond `mark_payment_link_sent` on first success.

## Tests Added Or Updated

- `test/fastcheck/sales/payments/transaction_initialization_test.exs` — happy
  path, missing email, cancelled order, stale initializing, expired
  `payment_link_sent` replay, log redaction.
- `test/fastcheck/sales/payments/paystack_initialization_idempotency_test.exs` —
  single Paystack call under replay/concurrency; in-progress guard; failed
  attempt does not block new active row.
- `test/fastcheck/sales/payments/paystack_initialization_security_test.exs` —
  operator forbidden; customer_session event scoping.
- `test/fastcheck/sales/payment_attempt_initialization_actions_test.exs` —
  `create_initializing` / `mark_initialized` / `mark_failed` /
  `mark_manual_review` transitions.
- `test/fastcheck/sales/checkout_and_payment_resource_migrations_test.exs` —
  `initializing` status and active idempotency index.
- `test/fastcheck/sales/checkout_and_payment_resource_skeletons_test.exs` and
  `test/fastcheck/sales/vs_01f_boundary_test.exs` — boundary inventory updated
  for VS-06B actions.

## Verification Reported

From PR #362 and local pre-merge runs:

- `mix test test/fastcheck/sales/payments/` — pass
- `mix precommit` — 604 tests, 0 failures, 4 skipped
- GitHub Actions CI run `27699332907` on
  `vs-06b-paystack-transaction-initialization` — success (~2m3s)

## Known Limitations

- Payment verification, webhook ingestion, and `PaymentEvent` recording belong
  to VS-07A+.
- Stale `initializing` recovery beyond `manual_review` is deferred (VS-07B/VS-07C).
- No end-to-end customer payment UI or WhatsApp payment-link delivery in this
  slice.
- `authorization_url` is returned to callers but must not be logged.

## Next Agent Guidance

**Reuse:**

- `FastCheck.Sales.Payments.TransactionInitialization` for any new init callers.
- `FastCheck.Payments.Paystack.*` for HTTP/HMAC only (VS-06A boundary).
- `FastCheck.Sales.Payments.TestSupport` and `:paystack_request_fun` injection
  in tests.
- Existing idempotency key format and active index semantics.

**Do not:**

- Add parallel Paystack initialization paths or call Paystack from Ash
  resources directly.
- Bypass session/order/hold/amount/email validation in the orchestrator.
- Replay authorization URLs for expired checkout sessions.
- Change idempotency index scope without a migration and concurrency tests.
- Log `authorization_url`, access codes, or buyer email from init flows.

**Authoritative tests to keep green:**

- `test/fastcheck/sales/payments/`
- `test/fastcheck/sales/payment_attempt_initialization_actions_test.exs`
- `test/fastcheck/payments/paystack/`
- full `mix precommit` before merge

## Next Slice

Recommended next slice:  
VS-06C — Paystack Initialization Tests

Entry condition:

- VS-06B merged on `main` with orchestrator, migration, and payment init tests
  green.
- VS-06A provider boundary unchanged as the sole Paystack HTTP layer.
- VS-06C hardens tests against VS-06B contracts; production behavior changes
  only when required to satisfy those contracts.
