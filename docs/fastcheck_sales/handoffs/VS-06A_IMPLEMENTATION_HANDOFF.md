# VS-06A Implementation Handoff

## Status

Merged.

PR: #359 — feat: implement VS-06A paystack provider boundary  
Merge commit: `f32674bddf96624c8da061f28b00d29c94e0ec1a`  
Merged at: 2026-06-17T10:51:02Z  
Branch: `vs-06a-paystack-client-boundary`

## What Changed

VS-06A added a plain Paystack provider boundary under
`FastCheck.Payments.Paystack` for config loading, HTTP calls via Req,
transaction initialization, transaction verification, webhook HMAC signature
verification, normalized safe errors, response sanitization, and safe Inspect
behavior.

Runtime and test config were wired with `PAYSTACK_ENABLED`-gated boot behavior.
Callback and webhook URLs are config-only placeholders for later slices. The
boundary uses `FastCheck.Observability.Redactor` and
`FastCheck.Observability.Correlation`; it does not touch Sales checkout,
`PaymentAttempt`/`PaymentEvent` persistence, routes, workers, or inventory.

## Files Changed

- `lib/fastcheck/payments/paystack/config.ex` — enabled-gated config load/validation;
  reference normalization; known channel list; safe Inspect for keys.
- `lib/fastcheck/payments/paystack/client.ex` — low-level Req execution, JSON
  decode, normalized `Error.t()`, correlation metadata, injectable
  `:paystack_request_fun`.
- `lib/fastcheck/payments/paystack/error.ex` — normalized provider error shape;
  message sanitization; safe Inspect.
- `lib/fastcheck/payments/paystack/initialize_result.ex` — initialize response
  struct; safe Inspect drops authorization URL/access code/safe_data.
- `lib/fastcheck/payments/paystack/response_sanitizer.ex` — redacts sensitive
  Paystack payload keys via `Redactor`.
- `lib/fastcheck/payments/paystack/transaction_initializer.ex` — `POST
  /transaction/initialize`; validates `amount_cents`, email, currency, metadata;
  returns `InitializeResult`.
- `lib/fastcheck/payments/paystack/transaction_verifier.ex` — `GET
  /transaction/verify/:reference`; returns normalized verify map with
  `safe_data`.
- `lib/fastcheck/payments/paystack/webhook_verifier.ex` — raw-body HMAC SHA512
  signature check with `Plug.Crypto.secure_compare/2`.
- `config/config.exs` — Paystack defaults (`PAYSTACK_ENABLED` off); injectable
  request fun.
- `config/runtime.exs` — env-driven Paystack config; prod fail-fast when
  enabled and keys missing.
- `config/test.exs` — fake Paystack keys and enabled flag for tests.
- `.env.example` — documented Paystack env vars.
- `docs/fastcheck_sales/slices/VS-06A_PAYSTACK_CLIENT_BOUNDARY.md` — slice
  summary and boundary confirmation.
- `test/fastcheck/payments/paystack/boundary_test.exs` — no controllers,
  workers, or Ash Sales coupling in provider modules.
- `test/fastcheck/payments/paystack/config_test.exs` — boot/call validation,
  reference rules, channel parsing.
- `test/fastcheck/payments/paystack/client_test.exs` — success/error
  normalization and timeout handling via request fun.
- `test/fastcheck/payments/paystack/error_test.exs` — message sanitization and
  safe Inspect.
- `test/fastcheck/payments/paystack/log_redaction_test.exs` — logs do not expose
  auth headers, access codes, or buyer PII.
- `test/fastcheck/payments/paystack/transaction_initializer_test.exs` —
  initialize payload/response mapping and validation.
- `test/fastcheck/payments/paystack/transaction_verifier_test.exs` — verify
  response normalization.
- `test/fastcheck/payments/paystack/webhook_verifier_test.exs` — HMAC
  signature acceptance/rejection.
- Historical Sales boundary tests — removed obsolete forbidden-path assertions;
  allow Paystack provider namespace in git-diff guards.

## Contracts Now Available

- `FastCheck.Payments.Paystack.Config.enabled?/0` and `get/0` read Application
  env; `validate_for_boot/0` passes when disabled; `validate_for_call/0`
  requires enabled plus keys/base URL/timeout/channels.
- `FastCheck.Payments.Paystack.Config.normalize_reference/1` enforces non-empty,
  max 100 chars, `^[A-Za-z0-9.\-=]+$`.
- `FastCheck.Payments.Paystack.Client.post/3` and `get/3` are the only HTTP
  entrypoints; tests inject via `:paystack_request_fun`.
- `FastCheck.Payments.Paystack.TransactionInitializer.initialize/2` accepts
  `amount_cents` (positive integer), `email`, optional `currency` (default
  `"ZAR"`), `reference`, `metadata`, optional `callback_url`; calls Paystack
  initialize API.
- `FastCheck.Payments.Paystack.TransactionVerifier.verify/2` fetches provider
  status by reference.
- `FastCheck.Payments.Paystack.WebhookVerifier.verify/3` and
  `valid_signature?/3` verify raw-body HMAC signatures.
- `FastCheck.Payments.Paystack.Error` is the normalized error type for all
  provider-boundary failures.
- Paystack modules do not reference Ash or Sales resource modules (enforced by
  boundary test).

## Decisions Applied

- Provider boundary only; no Sales workflow activation.
- `PAYSTACK_ENABLED=false` keeps boot safe without secrets; prod fail-fast only
  when enabled and required config is missing.
- Integer cents (`amount_cents`) for initialize amounts.
- Req via injectable `:paystack_request_fun`; no parallel HTTP client.
- Reuses VS-21A `Redactor` and `Correlation`; no ad-hoc redaction.
- Callback/webhook URLs stored as config only; no routes/controllers added.
- `organization_id` and multi-tenant Paystack config remain deferred.
- No Redis, inventory, Oban, or Ash resource changes in this slice.

## Boundaries Still Enforced

- No Sales checkout integration or `Checkout.start_checkout/3` wiring.
- No `PaymentAttempt` or `PaymentEvent` Ash actions or persistence wiring.
- No Paystack webhook route/controller or raw-body plug wiring.
- No Paystack Oban workers.
- No order/checkout/session state transitions.
- No payment verification applied to Sales state.
- No ticket issuance, WhatsApp/Meta, scanner/mobile, admin/customer payment UI.
- No refunds, cancellations, settlement, or manual-review logic.
- No Redis or inventory mutation.

## Tests Added Or Updated

- `test/fastcheck/payments/paystack/*` — 23 tests covering config, client,
  initialize, verify, webhook HMAC, errors, redaction, and namespace isolation.
- Historical `test/fastcheck/sales/*_boundary_test.exs` — updated allowlists only;
  no new Sales behavior.

## Verification Reported

From PR #359:

- `mix credo --strict` — pass
- `mix test test/fastcheck/payments/paystack/` — 23 tests, 0 failures
- `mix test test/fastcheck/sales/` — 183 tests, 0 failures
- `mix precommit` — 586 tests, 0 failures
- GitHub CI green on head commit `311358d54af5539057d16426fda04738c2a68893`

## Known Limitations

- Provider calls are available but not connected to checkout/order state.
- `TransactionVerifier` returns provider data only; it does not update
  `PaymentAttempt` or orders.
- `WebhookVerifier` is a pure module; no HTTP ingress or event persistence.
- `callback_url` / `webhook_url` env values are placeholders for VS-06B+ and
  VS-07A.
- Initialize does not decide whether a Sales order is valid for payment; that
  belongs to VS-06B.

## Next Agent Guidance

**Reuse:**

- All modules under `lib/fastcheck/payments/paystack/` as the sole Paystack HTTP
  and signature boundary.
- `TransactionInitializer.initialize/2` from service layer only (VS-06B), not
  from Ash resources or LiveViews directly.
- `TransactionVerifier.verify/2` and `WebhookVerifier.verify/3` for later
  verification/webhook slices.
- `:paystack_request_fun` injection in tests instead of live Paystack calls.
- `FastCheck.Observability.Redactor` and `Correlation` for any new Paystack
  logging/metadata.

**Do not:**

- Add Paystack HTTP or HMAC logic outside `FastCheck.Payments.Paystack.*`.
- Couple provider modules to `FastCheck.Sales.*` Ash resources.
- Wire initialize/verify into checkout LiveViews or secondary entrypoints in
  VS-06B-adjacent work without going through the planned service layer.
- Log raw provider payloads, secret keys, authorization URLs, or access codes.
- Recreate parallel config or error types.

**Authoritative tests to keep green:**

- `test/fastcheck/payments/paystack/`
- `test/fastcheck/sales/` (especially checkout and secondary entrypoint suites)
- full `mix precommit` before merge

## Next Slice

Recommended next slice:  
VS-06B — Paystack Transaction Initialization

Entry condition:

- VS-06A merged on `main` with provider boundary modules and tests green.
- VS-05 checkout core and VS-05A secondary entrypoints remain unchanged
  contracts for order/checkout state.
- VS-06B connects valid checkout/order state to
  `TransactionInitializer` through a service layer, creates/updates durable
  `PaymentAttempt` records, and still does not verify payment, issue tickets,
  or consume inventory.
