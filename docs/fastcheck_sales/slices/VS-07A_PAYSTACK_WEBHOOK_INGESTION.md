# VS-07A — Paystack Webhook Ingestion

## Status

Implemented on branch `vs-07a-paystack-webhook-ingestion`.

## What Changed

- Webhook-scoped `RawBodyReader` for `POST /api/sales/paystack/webhook`
- `FastCheckWeb.Webhooks.PaystackController` ingress
- `FastCheck.Sales.Payments.WebhookIngestion` orchestrator with atomic `Ecto.Multi` persist + Oban enqueue
- `FastCheck.Sales.Payments.PaystackWebhookWorker` shell on `:payments` queue
- `FastCheck.Payments.Paystack.{WebhookEventParser, EventDedupe}` helpers
- `FastCheck.Payments.Paystack.Config.validate_for_webhook/0`
- `FastCheck.Sales.PaymentEvent.store_webhook_event` action and summarized read policies

## Boundaries

- No `TransactionVerifier` calls
- No `PaymentAttempt`, `Order`, inventory, ticket, or scanner mutation
- Telemetry: `[:fastcheck, :sales, :payment, :webhook_received]` only

## Next Slice

VS-07B — Paystack Transaction Verification
