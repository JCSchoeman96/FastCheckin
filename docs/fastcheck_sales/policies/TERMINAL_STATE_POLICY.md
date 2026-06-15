# Terminal State Policy

## Purpose

Define terminal states and constrain recovery from them.

## Default Terminal States

| Resource | Terminal states |
|---|---|
| Order | `ticket_issued`, `cancelled`, `expired`, `refunded` |
| CheckoutSession | `paid`, `released`, `expired` |
| PaymentAttempt | `duplicate`, `refunded`, selected `failed` states |
| PaymentEvent | `processed`, `duplicate` |
| TicketIssue | `revoked` |
| DeliveryAttempt | `delivered`, `cancelled` |
| Conversation | `completed`, `cancelled`, `expired` |

## Recovery Rule

Terminal states may only be exited through explicitly documented admin/system
recovery actions. Recovery must:

- preserve audit history;
- create a new `StateTransition`;
- include a non-empty reason;
- avoid destructive rewrites;
- preserve verified payment and ticket evidence;
- avoid scanner-visible changes unless the target action owns scanner updates.

## Forbidden Recovery

- Generic status mutation from any terminal state.
- Deleting `StateTransition` records.
- Reopening refunded/revoked tickets without scanner-safe policy.
- Releasing consumed inventory.
- Customer-session recovery from terminal states.

## Future Tests

- Terminal states reject generic updates.
- Approved recovery requires reason and event-scoped access.
- Recovery preserves previous audit rows.
