# Sales State Machine Master

## Global Rules

- Generic `update_status` and `update_state` actions are forbidden.
- Every state transition requires `StateTransition` audit.
- Manual admin/operator transitions require a non-empty reason.
- System transitions preserve `correlation_id`, `request_id`, or
  `idempotency_key` where available.
- No customer-facing channel may say payment was not received once durable
  verified payment exists.
- Paystack webhook payload alone never produces verified payment state.
- Ticket issuance requires verified payment, a consumed inventory hold, and an
  Order that passed through `fulfillment_queued`.
- Admin Order refund or cancellation must not transition while an issued
  `TicketIssue` remains.
- A full refund requires manual Paystack Dashboard evidence with provider
  status `processed`, a refund RRN/reference, `refunded_at`, exact full amount
  and currency, an event-scoped admin, a reason, and the existing admin
  password.
- Refund revocation must complete before financial finalization. The only
  named Order refund action is `finalize_refund`.
- Reconciliation may make capacity available only for a completed Refund with
  `released_unconsumed` inventory resolution. Consumed and unresolved cases
  remain unavailable.

## Actor Types

| Actor type | Meaning |
|---|---|
| `system` | Worker, webhook processor, internal service, or trusted backend process. |
| `admin` | Authorized admin with event-scoped access. |
| `operator` | Event-scoped operations user with narrower access than admin. |
| `customer_session` | Token/session-scoped customer flow; never broad reads or writes. |

## State Machines

- `Order`: durable order lifecycle.
- `CheckoutSession`: checkout hold/payment-link lifecycle.
- `PaymentAttempt`: provider transaction lifecycle.
- `Refund`: durable refund evidence, revocation, financial finalization, and
  inventory-resolution lifecycle.
- `PaymentEvent`: webhook/event processing lifecycle.
- `TicketIssue`: ticket validity/issuance lifecycle.
- `TicketDeliveryIntent`: one logical customer ticket-delivery lifecycle.
- `DeliveryAttempt`: delivery audit lifecycle.
- `Conversation`: WhatsApp/customer interaction lifecycle.

## Dangerous Preconditions

| Transition | Required preconditions |
|---|---|
| `mark_paid_verified` | Paystack server-side verification success, amount match, currency match, provider reference match, event ownership match. |
| `queue_fulfillment` | Verified `PaymentAttempt`, paid `CheckoutSession`, exactly one `OrderLine`, and its exact hold confirmed consumed. Set `fulfillment_queued_at` and insert `IssueTicketsWorker` atomically in Postgres. |
| `mark_ticket_issued` | Order already passed `fulfillment_queued`; all attendee and `TicketIssue` rows exist. For WhatsApp orders, the `TicketDeliveryCoordinatorWorker` handoff is inserted in the same Postgres transaction as the transition. |
| `revoke_issued_ticket` | Revocation reason, scanner visibility update, mobile sync aggregation, token invalidation, and audit reason exist. Order-level revocation holds the shared Order advisory lock, pages every issued row, and verifies zero remain. |
| `Order.finalize_refund` / `Refund.mark_inventory_pending` | A matching Refund has accepted full Paystack Dashboard evidence, revocation is complete, and an authoritative issued TicketIssue count is zero immediately before the final transition under the same Order advisory lock. The transaction marks PaymentAttempt refunded, Order refunded, Refund inventory_pending, and inserts RefundInventoryWorker. |
| `complete_released_unconsumed` / `complete_retained_consumed` / `retry_refund_inventory` | The worker completes from `inventory_pending` only after proving an exact refund-specific held release or exact consumed hold. An audited retry moves `inventory_manual_review` back to `inventory_pending`. Ambiguous or exhausted cases stay unavailable in `inventory_manual_review`. |

## Refund lifecycle

The Refund resource allows only these states:

```text
evidence_recorded
revocation_complete
inventory_pending
revocation_manual_review
inventory_manual_review
completed
```

Named transitions are `record_full_refund_evidence`,
`mark_revocation_complete`, `mark_revocation_manual_review`,
`retry_refund_revocation`, `mark_inventory_pending`, `complete_released_unconsumed`,
`complete_retained_consumed`,
`mark_inventory_manual_review`, and `retry_refund_inventory`. Generic status
updates are forbidden. A failed revocation retains evidence and prevents
financial finalization. A failed or ambiguous inventory resolution retains
capacity as unavailable.

The Order's separate named financial action is `finalize_refund`; it performs
the Order, PaymentAttempt, Refund, and worker updates in one transaction.

An audited revocation retry returns `revocation_manual_review` to
`evidence_recorded` before rerunning revocation. An audited inventory retry
returns `inventory_manual_review` to `inventory_pending` and requeues work by
Refund ID.

P1-C does not reclaim consumed inventory. Browser admission, asynchronous
mobile database persistence, and the Android local-first queue/overlay do not
provide one global unused-ticket proof. Future consumed-capacity reclaim is
blocked on unified admission/usage authority and fencing under
`FastCheckin-52n8`.

## Future Test Expectations

Later implementation slices must add allow/deny tests for legal and forbidden
transitions, idempotent retry tests for worker/webhook actions, and policy tests
for event-scoped actor permissions.
