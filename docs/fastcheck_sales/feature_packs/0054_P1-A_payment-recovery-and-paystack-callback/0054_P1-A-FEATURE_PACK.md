# P1-A payment recovery and Paystack callback

## Goal

Recover unresolved Paystack attempts when the normal webhook or verification job
handoff is lost. Expose the configured browser callback at
`GET /sales/payments/paystack/callback` and keep its response safe for buyers.

## Payment authority

The webhook payload and browser callback are triggers. Neither proves payment.
FastCheck verifies every candidate with Paystack's Transaction Verify API:

```text
Paystack Transaction Verify API
        ↓
FastCheck.Payments.Paystack.TransactionVerifier
        ↓
FastCheck.Sales.Payments.PaymentVerification
        ↓
PaymentOutcomes → PaymentOutcomeHandler
```

The outcome handler retains authority over payment state and the existing paid
order lifecycle. Recovery does not change payment state, inventory, or ticket
records.

## Payment triggers

```text
PRIMARY:
Paystack webhook → WebhookIngestion → PaymentEvent and PaystackWebhookWorker

FALLBACK:
PaymentRecoverySweepWorker → VerifyPaymentWorker or PaystackWebhookWorker

CUSTOMER RETURN:
Paystack browser callback → PaymentRecovery → VerifyPaymentWorker
```

The webhook worker still finds the attempt by provider and provider reference.
The verification worker delegates to `PaymentVerification`. A successful
verification follows the existing paid order handoff, including
`PaidOrderFulfillmentWorker`.

## Scheduled recovery

The existing Oban Cron plugin runs `PaymentRecoverySweepWorker` every two
minutes on `sales_maintenance`. `CheckoutExpirySweeperWorker` keeps its current
schedule. Recovery reads at most 200 rows from each indexed stream per sweep,
ordered by `inserted_at` and `id`.

An attempt becomes eligible after 120 seconds and remains eligible for up to
900 seconds after insertion. The recoverable attempt states are:

```text
initialized
authorization_url_sent
webhook_received
verification_started
verification_retry_queued
```

`verification_started` does not prove that a verification job still exists. A
later sweep can enqueue a fresh job after the existing five-minute worker
uniqueness period expires. `verification_retry_queued` is eligible only after
the existing operator review action placed it in that state.

The event stream accepts signed `PaymentEvent` rows in these states:

```text
stored
processing_started
unmatched
failed
```

The sweep re-enqueues `PaystackWebhookWorker`. It skips unsigned events and
events that match a terminal attempt, except `verified_success`. A successful
attempt's recoverable event is re-driven through the existing idempotent
verification path so the event can be finalized without another Paystack call.
It does not create a second event. Attempts in `verified_success`, mismatch,
`duplicate`, `manual_review`, `failed`, or `refunded` are not automatically
verified again by the attempt recovery stream.

When the 15-minute horizon expires, the sweep stops polling. It does not mark
the payment failed. The checkout expiry lifecycle remains authoritative, and a
later webhook or callback may still trigger the existing late-payment flow.
Pending and temporarily unavailable provider results retain their current
retryable classification.

## Browser callback

The route runs in the public browser pipeline, outside dashboard authentication
and the provider webhook pipeline. It accepts `reference` or `trxref`,
normalized through `PaystackConfig.normalize_reference/1`. If both are present,
they must normalize to the same reference. Invalid, mismatched, unknown, and
terminal references all receive the same static page.

The callback ignores query values such as `status`, `success`, `amount`,
`currency`, `email`, and `customer`. It never calls Paystack synchronously and
never renders a provider reference, Order identifier, buyer details, or amount.
The page says:

> We're checking your payment. You can return to WhatsApp. If Paystack confirms
> the payment, your ticket will be processed automatically.

The response sets `Cache-Control: no-store`, `Referrer-Policy: no-referrer`,
and `X-Robots-Tag: noindex, nofollow`. The browser pipeline keeps the existing
CSP and security headers.

## Verification coverage

Regression tests cover recovery without a webhook, stale and terminal attempt
states, the 15-minute horizon, bounded batches, discarded verification jobs,
all recoverable event states, and simultaneous sweep execution. Callback tests
cover accepted reference inputs, malformed and mismatched references, unknown
references, the safe response and headers, server-side verification, and a
callback/webhook race with one paid transition, one inventory consume, and one
fulfillment chain.

Existing payment, mismatch, timeout, pending, late-payment, webhook, worker, and
P0-B fulfillment tests remain in the verification set. No migration or index
change is part of P1-A.
