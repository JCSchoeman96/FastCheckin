# P0-B Paid Order Fulfillment

## Goal

Make a successfully verified payment progress through inventory consumption to
a durable ticket-issuance job without requiring a person or a manual worker
invocation.

## Runtime law

```text
PaymentAttempt = verified_success
Order = paid_verified
CheckoutSession = paid
PaidOrderFulfillmentWorker is in the same Postgres transaction
        ↓
PaidOrderFulfillment validates the durable authority
        ↓
ReservationLedger consumes the exact OrderLine hold outside Postgres TX
        ↓
one Postgres TX: advisory Order lock, queue_fulfillment, IssueTicketsWorker insert
        ↓
Order = fulfillment_queued and fulfillment_queued_at is set
```

The coordinator starts from `payment_attempt_id`; the Order relationship is
loaded from that record. It requires an exact verified amount and currency, a
paid CheckoutSession, and exactly one OrderLine. Inventory consume uses
`paid_order_fulfillment:consume:<payment_attempt_id>`. A retry accepts an
already-consumed hold only when offer, public Order reference, quantity, and
status all match. This supports late-payment recovery without consuming twice.

For active checkouts, Paystack verification commits the verified attempt, paid
Order, paid CheckoutSession, and fulfillment-worker job in one Postgres
transaction. That transaction does not call Redis or enqueue
`IssueTicketsWorker` directly. Repeated verification can restore the handoff
while the Order remains eligible. Late-payment recovery may re-establish a valid
held reservation, but it does not consume inventory. The paid attempt, paid
Order, paid CheckoutSession, finalized PaymentEvent, and fulfillment-worker job
commit in the same Postgres transaction for both active and late payments. If
that transaction fails, the hold remains held and the same recovery key makes
the next verification safe. Final consumption occurs only in
`PaidOrderFulfillment` after the paid-state transaction commits.

## Failure and crash behavior

- The payment transaction includes the `PaidOrderFulfillmentWorker` insert. If
  the insert fails, paid-state changes roll back.
- Redis outage or lock contention is retryable. A retry never downgrades paid
  state or enqueues issuance early.
- An idempotent consume response still checks ledger health. A degraded or
  reconciliation-required ledger cannot authorize ticket issuance.
- Missing, expired, released, mismatched, or unhealthy inventory fails closed
  to manual review. Verified payment evidence remains durable.
- Inventory consume is outside Postgres TX. If the process exits after consume,
  a retry validates the exact consumed hold and proceeds.
- The Order transition, `fulfillment_queued_at`, and `IssueTicketsWorker` insert
  share one Postgres transaction. A queue insertion failure rolls all three
  back while leaving consumed inventory intact.
- A process exit after that transaction leaves both the queued Order and issuer
  job durable.
- Retry exhaustion moves the paid Order to manual review with a stable reason
  code and emits existing manual-review telemetry.
- An operator can retry an eligible pre-fulfillment manual-review Order through
  `retry_paid_order_fulfillment`. The service revalidates verified payment,
  amount/currency, paid CheckoutSession, one OrderLine, allowed inventory
  failure reason, no prior fulfillment timestamp, and no issued TicketIssue.
  The `manual_review -> paid_verified` transition, audit action, and
  `PaidOrderFulfillmentWorker` insert share one Postgres transaction; the
  action does not mutate Redis.

## Issuance and manual-review boundaries

- `IssueTicketsWorker` and `Issuer.issue_order/2` do not accept `paid_verified`.
- `Order.mark_ticket_issued` cannot transition directly from `paid_verified`.
- Manual issuance retry and return-to-queue require
  `fulfillment_queued_at != nil`.
- Returning to fulfillment atomically transitions the Order and inserts a new
  idempotent issuer job. Manual-review actions do not mutate Redis inventory.
- Pre-fulfillment retry is distinct from issuance retry and cannot enqueue
  `IssueTicketsWorker` directly.
- This pack does not add ticket delivery behavior.

## Verification

Focused tests cover payment handoff transactionality, deterministic consume,
already-consumed hold matching, unsafe and transient ledger outcomes, retry
exhaustion, crash-after-consume recovery, database and issuer-insert rollback,
issuer authorization, manual-review gates and recovery, late-payment database
rollback with held inventory, and the checkout-to-scanner flow. One narrow
migration extends only the manual-review action check constraint; no new
persistence model, Redis structure, index, or Oban queue is required.
