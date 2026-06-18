# VS-07A Implementation Handoff

## Status

Merged.

PR: #366 — feat(sales): VS-07A Paystack webhook ingestion  
Merge commit: `2e6b201a2ff199611e50e88a52e0260ecb104aa3`  
Merged at: 2026-06-18T13:43:34Z  
Branch: `vs-07a-paystack-webhook-ingestion`

## What Changed

VS-07A added ingestion-only Paystack webhook ingress. Signed provider callbacks
arrive at `POST /api/sales/paystack/webhook`, are verified against the raw request
body, deduped via Redis SETNX plus DB unique constraints, persisted as
`PaymentEvent` rows with `processing_status: "stored"`, and enqueued to
`PaystackWebhookWorker` in one `Ecto.Multi` transaction. Duplicate deliveries
return `200` and recover missing Oban jobs when the event row already exists.

No transaction verification, `PaymentAttempt` mutation, paid-order transitions,
ticketing, inventory, WhatsApp, or scanner/mobile changes were added.

## Files Changed

- `lib/fastcheck_web/plugs/raw_body_reader.ex` — webhook-scoped `Plug.Parsers`
  body reader; stores `conn.private[:raw_body]` only for
  `POST /api/sales/paystack/webhook`; single `read_body/2` call (no unbounded
  chunk accumulation).
- `lib/fastcheck_web/endpoint.ex` — registers `RawBodyReader`; rescues
  `Plug.Parsers.ParseError` for the Paystack webhook path only and returns `400`.
- `lib/fastcheck_web/router.ex` — `:webhook` pipeline and
  `POST /api/sales/paystack/webhook` route.
- `lib/fastcheck_web/controllers/webhooks/paystack_controller.ex` — thin HTTP
  ingress mapping ingest results to `200` / `401` / `400` / `503` / `500`.
- `lib/fastcheck/sales/payments/webhook_ingestion.ex` — Sales orchestrator:
  HMAC verify, dedupe, atomic persist + enqueue, duplicate/orphan recovery.
- `lib/fastcheck/sales/payments/paystack_webhook_worker.ex` — Oban shell on
  `:payments` queue; loads event and emits telemetry only.
- `lib/fastcheck/payments/paystack/webhook_event_parser.ex` — pure metadata
  extraction (`provider_event_id`, `provider_reference`, `event_type`).
- `lib/fastcheck/payments/paystack/event_dedupe.ex` — Redis SETNX dedupe with
  `claim/1` and `release/1`.
- `lib/fastcheck/payments/paystack/config.ex` — `validate_for_webhook/0`
  (enabled + secret only; not `validate_for_call/0`).
- `lib/fastcheck/sales/payment_event.ex` — `store_webhook_event`,
  `get_by_provider_event_id`, `get_by_provider_payload_hash`; system create;
  admin/operator summarized reads; `raw_payload` system-only.
- `config/config.exs` — Oban `payments: 5` queue.
- `docs/fastcheck_sales/slices/VS-07A_PAYSTACK_WEBHOOK_INGESTION.md` — slice
  summary and boundaries.
- `test/fastcheck_web/controllers/webhooks/paystack_controller_test.exs` — HTTP
  ingress: valid signed webhook, invalid signature, malformed JSON via real
  route, duplicate delivery, raw-body HMAC, raw-body scope, webhook-only config.
- `test/fastcheck/sales/payments/webhook_ingestion_test.exs` — atomic persist +
  enqueue, payload-hash dedupe, duplicate job recovery, Multi rollback.
- `test/fastcheck/sales/payments/paystack_webhook_worker_test.exs` — worker
  telemetry shell and missing-event handling.
- `test/fastcheck/payments/paystack/webhook_{dedupe,security,boundary}_test.exs`
  — Redis dedupe, policy/log redaction, static boundary guards.
- `test/support/sales_payments_test_support.ex` — webhook signing helpers and
  dedupe key flush.
- `test/support/sales_boundary_allowlist.ex` — VS-07A webhook paths allowed in
  historical git-diff boundary tests.
- Updated VS-01C–01G skeleton/boundary/policy tests — allow `store_webhook_event`
  and Sales-domain webhook worker path.

## Contracts Now Available

- Route: `POST /api/sales/paystack/webhook` (unauthenticated HTTP; HMAC on raw
  body via `x-paystack-signature`).
- `FastCheck.Sales.Payments.WebhookIngestion.ingest/3` — authoritative ingestion
  orchestrator for Paystack webhooks.
- `FastCheck.Payments.Paystack.Config.validate_for_webhook/0` — webhook config
  gate (enabled + `paystack_secret_key` only).
- `FastCheck.Sales.PaymentEvent.store_webhook_event` — system-only create with
  `transaction?(false)` for `Ecto.Multi` participation.
- `FastCheck.Sales.Payments.PaystackWebhookWorker` at
  `lib/fastcheck/sales/payments/paystack_webhook_worker.ex` (not
  `lib/fastcheck/workers/`); args `%{"payment_event_id" => id}`; Oban queue
  `:payments`.
- New `PaymentEvent` rows use `processing_status: "stored"`; no FK to
  `PaymentAttempt` yet.
- Telemetry on worker perform:
  `[:fastcheck, :sales, :payment, :webhook_received]`.
- Duplicate delivery: `200`, one row, one job; missing job re-enqueued before
  duplicate response.
- Orphaned Redis dedupe keys (after rolled-back persist) are released and
  retried.

## Decisions Applied

- Ingestion-only slice; verification deferred to VS-07B.
- Webhook-scoped raw body capture; other routes do not retain `raw_body`.
- Provider HTTP/crypto stays in `FastCheck.Payments.Paystack.*`; Sales
  orchestration in `FastCheck.Sales.Payments.WebhookIngestion`.
- Redis dedupe is best-effort (`:redis_unavailable` falls through to DB unique
  constraints).
- `raw_payload` and `last_processing_error` are system-only fields; admin and
  operator get summarized `PaymentEvent` reads.
- Webhook pipeline accepts `json`, `text`, `*/*` only (no `html`) to satisfy
  Sobelow secure-headers checks for machine-to-machine callbacks.
- No new migrations; uses existing `sales_payment_events` table and identities
  from VS-01C.

## Boundaries Still Enforced

- No `FastCheck.Payments.Paystack.TransactionVerifier` calls.
- No `PaymentAttempt`, `Order`, `CheckoutSession`, inventory, ticket, or
  fulfillment mutation from webhook ingress or worker.
- No paid-order transitions or ticket issuance.
- No WhatsApp/Meta, scanner/mobile API, or admin/customer payment UI wiring.
- No `PaymentEvent` → `PaymentAttempt` linkage in this slice.
- Worker does not change `processing_status` beyond loading the stored row.

## Tests Added Or Updated

- `test/fastcheck_web/controllers/webhooks/paystack_controller_test.exs` — full
  HTTP ingress including malformed JSON on the real route with valid HMAC.
- `test/fastcheck/sales/payments/webhook_ingestion_test.exs` — orchestrator
  happy path, dedupe, duplicate job recovery, Multi rollback.
- `test/fastcheck/sales/payments/paystack_webhook_worker_test.exs` — worker
  shell and telemetry.
- `test/fastcheck/payments/paystack/webhook_dedupe_test.exs` — Redis SETNX
  claim/release.
- `test/fastcheck/payments/paystack/webhook_security_test.exs` — summarized
  reads, `raw_payload` forbidden for admin/operator, ingest log redaction.
- `test/fastcheck/payments/paystack/webhook_boundary_test.exs` — no
  `TransactionVerifier`, no order/payment/ticket mutation in ingestion/worker
  source.
- `test/fastcheck/payments/paystack/boundary_test.exs` — Sales webhook modules
  exist outside provider namespace; legacy `lib/fastcheck/workers/` path absent.
- VS-01C–01G boundary/skeleton/policy tests updated for `store_webhook_event`
  and VS-07A allowlist entries.

## Verification Reported

From PR #366 test plan and local runs on merge head `f3622a7`:

```bash
mix test test/fastcheck_web/controllers/webhooks/ \
  test/fastcheck/sales/payments/webhook_ingestion_test.exs \
  test/fastcheck/sales/payments/paystack_webhook_worker_test.exs \
  test/fastcheck/payments/paystack/webhook_*
mix test test/fastcheck/sales/payments/ test/fastcheck/payments/paystack/ \
  test/fastcheck/sales/vs_01f_policy_test.exs \
  test/fastcheck/sales/vs_01g_index_and_migration_verification_test.exs
mix sobelow --exit --compact
mix precommit
```

Results reported:

- VS-07A focused suites — 25 tests, 0 failures
- Sales/payments + paystack regression — 86 tests, 0 failures
- `mix sobelow --exit --compact` — pass
- `mix precommit` — 645 tests, 0 failures, 4 skipped
- GitHub Actions CI run `27763505672` on `vs-07a-paystack-webhook-ingestion`
  (head `f3622a7`) — pass (~2m6s); Sobelow, DB migrate, and full test suite green

## Known Limitations

- `PaystackWebhookWorker` is a telemetry shell only; it does not verify
  transactions or update business state.
- `PaymentEvent` rows are not linked to `PaymentAttempt` / Paystack reference
  matching yet.
- `processing_status` remains `"stored"` after ingest; no `mark_processed` or
  failure transitions in this slice.
- Staging/production Paystack webhook URL configuration and live callback smoke
  test were not part of the merged PR.
- Malformed JSON with `application/json` is rejected at the endpoint parser
  rescue (`400`) before `WebhookIngestion` runs; syntactically valid JSON with
  missing event metadata is rejected by the orchestrator (`400`).

## Next Agent Guidance

**Reuse:**

- `FastCheck.Sales.Payments.WebhookIngestion` as the sole webhook ingest API.
- `FastCheckWeb.Plugs.RawBodyReader` + `conn.private[:raw_body]` for HMAC on
  exact request bytes.
- `FastCheck.Sales.Payments.PaystackWebhookWorker` on `:payments` queue for
  async follow-up (extend in VS-07B, do not create a parallel worker under
  `lib/fastcheck/workers/`).
- `FastCheck.Sales.Payments.TestSupport` webhook helpers (`sign_webhook_body/1`,
  `charge_success_webhook_body/1`, `flush_webhook_dedupe_keys!/0`).
- All `test/fastcheck_web/controllers/webhooks/` and
  `test/fastcheck/sales/payments/webhook_*` suites as authoritative ingress
  boundary tests.

**Do not:**

- Call `TransactionVerifier` from ingress or VS-07A worker shell without a new
  slice plan.
- Use `validate_for_call/0` for webhook config checks.
- Bypass `WebhookIngestion` from controllers or workers.
- Recursively accumulate `{:more, ...}` body chunks in `RawBodyReader`.
- Expose `raw_payload` to admin/operator actors.
- Add `PaymentEvent` FK to `PaymentAttempt` without an explicit migration slice.

**Keep green:**

- `test/fastcheck/sales/payments/` (initialization + webhook suites)
- `test/fastcheck/payments/paystack/`
- `test/fastcheck_web/controllers/webhooks/paystack_controller_test.exs`
- `mix precommit`

## Next Slice

Recommended next slice: **VS-07B — Paystack Transaction Verification**

Entry condition:

- VS-07A merged and `POST /api/sales/paystack/webhook` ingests signed events into
  `sales_payment_events` with `PaystackWebhookWorker` jobs on `:payments`.
- `FastCheck.Payments.Paystack.TransactionVerifier` exists in the provider
  boundary from VS-06A but is not yet wired to webhook processing.
- VS-07B should extend `PaystackWebhookWorker` (or a closely related Sales
  orchestrator) to verify transactions, link events to `PaymentAttempt` rows,
  and drive payment state transitions per the Sales payment plan—without
  re-implementing ingestion or moving the worker to `lib/fastcheck/workers/`.
