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

The outcome handler retains authority over payment outcomes and the existing
paid order lifecycle. Recovery may use the existing PaymentAttempt transitions
to enter or queue manual review; it never marks payment paid, changes Order
payment state, touches inventory, or issues tickets.

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

For a signed matching event, `PaystackWebhookWorker` loads the event and attempt
inside one Repo transaction, takes the order advisory lock, reloads the attempt,
and then decides any recovery transition. The PaymentAttempt transition,
refreshed PaymentEvent transition, and VerifyPaymentWorker insertion commit or
roll back together. `PaymentRecovery.prepare_webhook_attempt/1` rejects calls
outside that transaction. A verified attempt can use the existing idempotent
event-finalization path; stale webhook data cannot move it back into retry.

## Scheduled recovery

The existing Oban Cron plugin runs `PaymentRecoverySweepWorker` every two
minutes on `sales_maintenance`. `CheckoutExpirySweeperWorker` keeps its current
schedule. Recovery reads at most 200 rows from each indexed stream per sweep,
ordered by `inserted_at` and `id`.

Automatic polling starts after 120 seconds and is bounded to 900 seconds after
attempt creation. The sweep reads at most 200 attempts total, including stale
attempts and orphaned operator retries. The recoverable attempt states are:

```text
initialized
authorization_url_sent
webhook_received
verification_started
verification_retry_queued
```

`verification_started` does not prove that a verification job still exists. A
later sweep can enqueue a fresh job when no `available`, `scheduled`,
`executing`, or `retryable` verification job exists. If the final Verify worker
attempt remains retryable, or an attempt outlives its horizon without a live
job, PaymentRecovery transitions it to `manual_review` with reason
`payment_verification_recovery_exhausted`. It never converts a pending result
to provider failure.

Old `verification_retry_queued` attempts remain eligible because that state
records fresh operator intent. If the queued job disappears before it starts,
the sweep can recreate it without relying on the attempt's original
`inserted_at` value. This does not start an automatic polling loop.

A signed webhook or valid callback may restart only an attempt in manual review
for `payment_verification_recovery_exhausted`, through the existing
`queue_verification_retry` transition and VerifyPaymentWorker. That triggered
retry is bounded to one additional verification cycle. If it also exhausts,
the attempt remains in manual review with reason
`payment_verification_recovery_retry_exhausted`; another callback or webhook
cannot restart it automatically. Other manual-review reasons remain protected
for operator review.

The event stream accepts signed `PaymentEvent` rows in these states:

```text
stored
processing_started
unmatched
failed
```

The sweep re-enqueues `PaystackWebhookWorker` for signed events. It does not
create a second event. A successful attempt's recoverable event is re-driven
through the existing idempotent verification path so the event can be finalized
without another Paystack call. Unrelated terminal attempt states do not trigger
verification; a matching event is moved to manual review. Attempts in
`verified_success`, mismatch, `duplicate`, `manual_review`, `failed`, or
`refunded` are not automatically verified again by the attempt recovery stream.

After the 15-minute horizon, the sweep stops automatic provider polling and
places unresolved attempts into the explicit recovery-exhausted review state
once no live verification worker remains. Attempts already queued by a trusted
late trigger use the named retry state and may complete the normal late-payment
flow. The checkout expiry lifecycle remains authoritative. Pending and
temporarily unavailable provider results retain their current retryable
classification.

## Browser callback

The route runs in the public browser pipeline, outside dashboard authentication
and the provider webhook pipeline. It accepts `reference` or `trxref`,
normalized through `PaystackConfig.normalize_reference/1`. If both are present,
they must normalize to the same reference. Invalid, mismatched, unknown, and
terminal references all receive the same static page.

The callback ignores query values such as `status`, `success`, `amount`,
`currency`, `email`, and `customer`. It never calls Paystack synchronously and
never renders a provider reference, Order identifier, buyer details, or amount.
An exact recovery-exhausted manual-review attempt can enter the approved retry
state; arbitrary manual-review and terminal attempts are safe no-ops.
The page says:

> We're checking your payment. You can return to WhatsApp. If Paystack confirms
> the payment, your ticket will be processed automatically.

The response sets `Cache-Control: no-store`, `Referrer-Policy: no-referrer`,
and `X-Robots-Tag: noindex, nofollow`. The browser pipeline keeps the existing
CSP and security headers.

## Verification coverage

Regression tests cover recovery without a webhook, pending verification
exhaustion, checkout expiry, attempts aged by an application outage, old
operator retries, discarded jobs, the bounded horizon, bounded batches,
live-job protection, all recoverable event states, and simultaneous sweeps. Callback tests
cover accepted reference inputs, malformed and mismatched references, unknown
references, the safe response and headers, server-side verification, and a
callback/webhook race with one paid transition, one inventory consume, and one
fulfillment chain. Late callback and signed-webhook tests prove the precise
recovery-exhausted retry path; unrelated manual-review reasons remain protected.

Existing payment, mismatch, timeout, pending, late-payment, webhook, worker, and
P0-B fulfillment tests remain in the verification set. No migration or index
change is part of P1-A.

The late-webhook concurrency regression uses separate PostgreSQL connections and
proves the callback waits on the same order advisory lock until the webhook
handoff transaction commits. A constrained VerifyPaymentWorker insert also
proves the attempt and PaymentEvent transitions roll back together on handoff
failure.
