# P1-C durable refund evidence

## Goal

Record an authorized full Paystack refund from the Paystack Dashboard, revoke
the order's issued tickets, finalize the financial states durably, and resolve
the exact inventory hold without guessing about consumed capacity.

P1-C records manual provider evidence. It does not call a Paystack refund API,
poll Paystack for refund status, or accept partial refunds.

## Required evidence

An admin may record a refund only when all of the following values are present
and match the selected verified payment attempt:

| Evidence | Requirement |
|---|---|
| Provider | `paystack` |
| Provider status | `processed` |
| Provider reference | Non-empty Paystack refund RRN or reference |
| Refunded time | `refunded_at` from the Dashboard |
| Amount | Exact full Order/payment amount |
| Currency | Exact Order/payment currency |
| Admin | Existing event-scoped admin identity |
| Reason | Non-blank audit reason |
| Password | Existing admin password, checked by the current authentication boundary |

The form must say that the admin completed a full refund in the Paystack
Dashboard and that FastCheck makes no provider refund call. Evidence is stored
before ticket revocation. Identical repeated evidence is idempotent; conflicting
evidence is rejected. Evidence never proves that a partial refund is acceptable.

The durable Refund is unique to the Order and selected PaymentAttempt. Its
inventory resolution stays empty until the inventory worker finishes.

## Refund lifecycle

The durable `Refund` record has exactly these lifecycle states:

```text
evidence_recorded
revocation_complete
inventory_pending
revocation_manual_review
inventory_manual_review
completed
```

Only the named transitions below may change these states. Generic status or
state updates are forbidden.

| From | To | Named transition | Authority and condition |
|---|---|---|---|
| new record | `evidence_recorded` | `record_full_refund_evidence` | An admin records the complete evidence above. |
| `evidence_recorded` | `revocation_complete` | `mark_revocation_complete` | Existing order revocation finishes and the authoritative issued-ticket count is zero. |
| `evidence_recorded` | `revocation_manual_review` | `mark_revocation_manual_review` | Revocation cannot complete safely; retain the evidence and reason. |
| `revocation_manual_review` | `evidence_recorded` | `retry_refund_revocation` | An audited retry returns to the recorded-evidence state, then reruns revocation and checks zero issued tickets. |
| `revocation_complete` | `inventory_pending` | `Refund.mark_inventory_pending` | `Order.finalize_refund` and this Refund transition pass all authority checks under the existing Order advisory lock in one transaction. |
| `inventory_pending` | `completed` | `complete_released_unconsumed` or `complete_retained_consumed` | The worker proves an exact refund-specific held release or an exact consumed hold. |
| `inventory_pending` | `inventory_manual_review` | `mark_inventory_manual_review` | The hold is missing, expired, malformed, mismatched, or otherwise unverifiable, or retries are exhausted. |
| `inventory_manual_review` | `inventory_pending` | `retry_refund_inventory` | An audited admin retry requeues resolution by Refund ID. The worker then applies the appropriate completion transition. |

A failed retry remains in its manual-review state and records its reason. No
transition skips revocation. No transition reaches `completed` without an
inventory resolution.

## Revocation and financial finalization order

The admin flow is:

```text
record_full_refund_evidence
  -> evidence_recorded
  -> existing order-level revocation
  -> revocation_complete
  -> Order.finalize_refund + Refund.mark_inventory_pending
     under pg_advisory_xact_lock(order_id)
  -> PaymentAttempt = refunded
  -> Order = refunded
  -> Refund = inventory_pending
  -> RefundInventoryWorker(refund_id)
```

The finalization transaction reloads the Order, Refund, selected
`verified_success` PaymentAttempt, and issued-ticket count after acquiring the
existing Order advisory lock. It requires exactly one matching verified
payment attempt, exact full amount and currency, accepted evidence, completed
revocation, and zero issued `TicketIssue` rows. It atomically marks
`PaymentAttempt` as `refunded`, marks `Order` as `refunded`, marks `Refund` as
`inventory_pending`, and inserts the unique inventory worker. Redis is not
called in this transaction. A queue insertion failure rolls back all three
financial state changes.

If revocation fails, the evidence remains durable and the Refund moves to
`revocation_manual_review`. The Order and PaymentAttempt do not become
`refunded`.

## Inventory worker

`RefundInventoryWorker` accepts only `refund_id` and reloads the Refund, Order,
the one authoritative OrderLine, and its offer, public Order reference, and
quantity from Postgres.

- For an exact held hold, call `ReservationLedger.release/4` with
  `refund:release:<refund_id>`, the authoritative quantity, and an atomic
  unexpired-hold requirement. Complete only when that exact release succeeds
  or its matching idempotency result proves this Refund performed it. Store
  `released_unconsumed`.
- For an exact consumed hold, perform no Redis mutation and no counter
  adjustment. Retain the exact consumed hold, store `retained_consumed`, and
  complete the Refund.
- For a missing, expired, malformed, wrong-offer, wrong-quantity, or otherwise
  unverifiable hold, move to `inventory_manual_review` and keep capacity
  unavailable. Redis-unavailable and lock-timeout outcomes retry through Oban;
  final exhaustion moves to the same manual-review state.

Repeated held-release attempts use the same refund-specific idempotency key.
The worker never infers availability from `Order = refunded` alone.

## Reconciliation

Reconciliation may make capacity available only for a `completed` Refund with
the exact `released_unconsumed` resolution and matching Order/Paystack
PaymentAttempt, full amount/currency, processed provider evidence, completed
revocation, exactly one positive OrderLine whose total and currency match the
Order, and zero issued TicketIssues.
It keeps `retained_consumed`, `inventory_pending`,
`inventory_manual_review`, `revocation_manual_review`, and legacy refunded
Orders without a matching Refund unavailable. These cases produce anomalies;
ambiguous refund evidence sets `manual_review_required?` and prevents an upward
availability repair. The legacy anomaly is
`legacy_refund_without_provider_evidence`; pending and manual inventory
resolution anomalies identify the unresolved Refund.

## Consumed capacity boundary

P1-C does not reclaim consumed inventory. Browser admission, asynchronous
mobile database persistence, and the Android local-first queue/overlay do not
provide one global unused-ticket proof. Future consumed-capacity reclaim is
blocked on a unified admission/usage authority and fencing under
`FastCheckin-52n8`.

This slice does not modify scanners or Android runtime code. It does not add a
consumed-capacity reclaim operation, a partial refund path, a provider API
integration, or a generic state mutation action.
