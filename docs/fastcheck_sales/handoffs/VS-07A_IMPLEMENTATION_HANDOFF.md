# VS-07A Implementation Handoff

## Status

Ready for review.

Branch: `vs-07a-paystack-webhook-ingestion`  
Bead: `FastCheckin-43v` (closed)

## What Changed

VS-07A adds ingestion-only Paystack webhook ingress. Signed callbacks are verified
against the raw request body, deduped via Redis SETNX plus DB unique constraints,
persisted as `PaymentEvent` rows, and enqueued to `PaystackWebhookWorker` in one
`Ecto.Multi` transaction. Duplicate deliveries return `200` and recover missing
Oban jobs when the event row already exists. Orphaned Redis dedupe keys (after a
rolled-back persist) are released and retried automatically.

No transaction verification, payment/order/ticket mutation, or scanner/WhatsApp
side effects were added.

## Files Changed

- `lib/fastcheck_web/plugs/raw_body_reader.ex` — webhook-scoped raw body capture
- `lib/fastcheck_web/endpoint.ex` — custom `body_reader`
- `lib/fastcheck_web/router.ex` — `:webhook` pipeline and route
- `lib/fastcheck_web/controllers/webhooks/paystack_controller.ex` — HTTP ingress
- `lib/fastcheck/sales/payments/webhook_ingestion.ex` — orchestrator
- `lib/fastcheck/sales/payments/paystack_webhook_worker.ex` — Oban shell worker
- `lib/fastcheck/payments/paystack/{config,event_dedupe,webhook_event_parser}.ex`
- `lib/fastcheck/sales/payment_event.ex` — `store_webhook_event`, read helpers, policies
- `config/config.exs` — `payments: 5` Oban queue
- `test/...` — controller, ingestion, worker, dedupe, security, boundary suites
- `docs/fastcheck_sales/slices/VS-07A_PAYSTACK_WEBHOOK_INGESTION.md`

## Contracts Now Available

- `POST /api/sales/paystack/webhook` — HMAC-SHA512 on raw body via `x-paystack-signature`
- `FastCheck.Payments.Paystack.Config.validate_for_webhook/0` — enabled + secret only
- `FastCheck.Sales.PaymentEvent.store_webhook_event` — system-only create; admin/operator
  summarized reads; `raw_payload` system-only
- `FastCheck.Sales.Payments.PaystackWebhookWorker` — `:payments` queue, args
  `%{"payment_event_id" => id}`
- Telemetry: `[:fastcheck, :sales, :payment, :webhook_received]` on worker perform

## Validation

- `mix test test/fastcheck_web/controllers/webhooks/ test/fastcheck/sales/payments/ test/fastcheck/payments/paystack/` — 86 tests, 0 failures
- `mix precommit` — 645 tests, 0 failures

## Next Slice

VS-07B — Paystack Transaction Verification (wire worker to verifier; link events to attempts)
