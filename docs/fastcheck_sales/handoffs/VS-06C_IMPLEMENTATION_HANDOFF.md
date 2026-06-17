# VS-06C Implementation Handoff

## Status

Merged.

PR: #364 — test(sales): VS-06C Paystack initialization tests  
Merge commit: `1e52a53ec7a6044e4dabde7b4e2a4719f182b304`  
Merged at: 2026-06-17T19:04:46Z  
Branch: `vs-06c-paystack-initialization-tests`

## What Changed

VS-06C hardened Paystack transaction initialization after VS-06B. It added focused
tests for invalid order/checkout states, provider failures, config safety, actor
policy, log redaction, and boundary creep. It also patched the VS-06B orchestrator
so a Paystack `{:ok, result}` with nil or blank `authorization_url` is treated as
`:invalid_provider_response`, marks the `initializing` attempt `failed`, and does
not transition the checkout session to `payment_link_sent`.

No new payment lifecycle features, migrations, routes, workers, or Ash resources
were added.

## Files Changed

- `lib/fastcheck/sales/payments/transaction_initialization.ex` — orchestrator
  guard for blank `authorization_url`; returns `:invalid_provider_response` and
  calls `mark_provider_failure/4` instead of `mark_initialized`.
- `test/support/sales_payments_test_support.ex` — reusable Paystack test injectors:
  `flunk_paystack_request_fun/0`, `status_request_fun/2`, `timeout_request_fun/0`,
  `malformed_success_request_fun/0`.
- `test/fastcheck/sales/payments/transaction_initialization_test.exs` — extended
  coverage for invalid states, snapshot amount, StateTransition audit, provider
  timeout/401/500, malformed 200 missing URL, and log redaction.
- `test/fastcheck/sales/payments/paystack_initialization_config_test.exs` — missing
  secret and disabled Paystack config return safe errors without provider calls.
- `test/fastcheck/sales/payments/paystack_initialization_boundary_test.exs` — static
  guards that initialization does not couple to webhooks, verification, ticketing,
  WhatsApp, or Redis inventory.
- `test/fastcheck/sales/payments/paystack_initialization_security_test.exs` — admin
  actor allowed path; provider errors do not expose raw bodies.

## Contracts Now Available

- `initialized` `PaymentAttempt` rows must have a usable `authorization_url`; blank
  Paystack success responses fail closed as `:invalid_provider_response`.
- Failed malformed-success path: attempt `failed` with
  `failure_code: "invalid_provider_response"`; order stays `awaiting_payment`;
  session stays `hold_attached`; no `authorization_url` returned to caller.
- Init success map excludes `access_code` and raw provider payloads; amount comes
  from durable order/line snapshots, not live `TicketOffer` price.
- `test/fastcheck/sales/payments/` now has 32 tests covering init happy path,
  invalid states, idempotency (from VS-06B), config, security, and boundary
  isolation.
- `FastCheck.Sales.Payments.TestSupport` is the shared injector surface for Sales
  payment-init tests.

## Decisions Applied

- Test-hardening slice; production changes limited to one VS-06B contract gap.
- Malformed provider success uses existing `mark_failed` path, not `manual_review`.
- Provider HTTP remains in `FastCheck.Payments.Paystack.*`; orchestrator-only guard.
- No new idempotency keys, migrations, or parallel initialization paths.
- Reused VS-06B checkout fixtures, `:paystack_request_fun` injection, and
  `capture_log` redaction patterns.

## Boundaries Still Enforced

- No Paystack webhook controller, route, or worker.
- No payment verification (`TransactionVerifier`) or `PaymentEvent` persistence.
- No paid-order transitions, ticket issuance, inventory mutation, or fulfillment.
- No WhatsApp/Meta, scanner/mobile API, or admin/customer payment UI wiring.
- No direct Paystack HTTP from Ash resources or new provider-boundary modules.

## Tests Added Or Updated

- `test/fastcheck/sales/payments/transaction_initialization_test.exs` — invalid
  order/session states, snapshot amount, StateTransition audit, provider
  timeout/401/500, malformed 200 missing URL, access_code exclusion, log redaction.
- `test/fastcheck/sales/payments/paystack_initialization_config_test.exs` — missing
  secret and disabled Paystack config.
- `test/fastcheck/sales/payments/paystack_initialization_boundary_test.exs` — no
  verification/ticketing/inventory coupling in orchestrator source.
- `test/fastcheck/sales/payments/paystack_initialization_security_test.exs` — admin
  actor, raw provider body not in error maps, log redaction.
- `test/support/sales_payments_test_support.ex` — provider failure injectors.

Existing VS-06B tests unchanged and must stay green:
`paystack_initialization_idempotency_test.exs`, `payment_attempt_initialization_actions_test.exs`.

## Verification Reported

From PR #364 test plan and local runs on merge head:

```bash
mix test test/fastcheck/sales/payments/
mix test test/fastcheck/payments/paystack/
mix test test/fastcheck/sales/payment_attempt_initialization_actions_test.exs
mix precommit
```

Results reported:

- `mix test test/fastcheck/sales/payments/` — 32 tests, 0 failures
- `mix test test/fastcheck/payments/paystack/` — 23 tests, 0 failures
- targeted payment-init + paystack suites — 57 tests, 0 failures
- `mix precommit` — 622 tests, 0 failures, 4 skipped
- GitHub Actions CI run `27712676084` on `vs-06c-paystack-initialization-tests` — pass (~2m2s)

## Known Limitations

- Payment verification, webhook ingestion, and `PaymentEvent` recording belong
  to VS-07A+.
- `access_code` may still be absent on otherwise-valid provider responses; only
  `authorization_url` presence is enforced at orchestrator level.
- No end-to-end customer payment UI or WhatsApp payment-link delivery.
- Stale `initializing` recovery beyond `manual_review` remains deferred.

## Next Agent Guidance

**Reuse:**

- `FastCheck.Sales.Payments.TransactionInitialization` as the sole init API.
- `FastCheck.Sales.Payments.TestSupport` injectors for payment-init tests.
- All `test/fastcheck/sales/payments/` suites as authoritative init boundary tests.
- VS-06B idempotency key format and active index semantics unchanged.

**Do not:**

- Recreate parallel initialization paths or bypass orchestrator validation.
- Mark attempts `initialized` without a usable `authorization_url`.
- Add webhook/verification/ticketing logic into the initialization orchestrator.
- Log `authorization_url`, access codes, buyer email, or raw provider payloads.

**Authoritative tests to keep green:**

- `test/fastcheck/sales/payments/`
- `test/fastcheck/payments/paystack/`
- `test/fastcheck/sales/payment_attempt_initialization_actions_test.exs`
- full `mix precommit` before merge

## Next Slice

Recommended next slice:  
VS-07A — Paystack Webhook Ingestion

Entry condition:

- VS-06C merged on `main` with hardened init tests and blank-URL guard green.
- VS-06B orchestrator and VS-06A provider boundary unchanged as init HTTP layer.
- VS-07A may add webhook ingress only; initialization behavior is frozen unless
  a later slice finds a contract gap.
