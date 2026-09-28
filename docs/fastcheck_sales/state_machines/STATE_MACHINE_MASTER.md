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
| admin Order refund/cancellation | Complete order-level revocation succeeds and an authoritative issued TicketIssue count is zero immediately before the final transition under the same Order advisory lock. |

## Future Test Expectations

Later implementation slices must add allow/deny tests for legal and forbidden
transitions, idempotent retry tests for worker/webhook actions, and policy tests
for event-scoped actor permissions.
