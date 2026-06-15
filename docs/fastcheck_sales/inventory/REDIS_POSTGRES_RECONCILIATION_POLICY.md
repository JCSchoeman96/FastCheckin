# Redis Postgres Reconciliation Policy

## Durable Facts

Reconciliation uses:

- `TicketOffer.configured_quantity_available` or `initial_quantity`.
- Order statuses.
- CheckoutSession statuses and `expires_at`.
- OrderLine quantities.
- TicketIssue issued/revoked states.
- PaymentAttempt `verified_success` and manual-review states.

## General Admission Formula

```text
configured_quantity
- consumed_quantity_from_issued_or_paid_fulfillment_orders
- active_hold_quantity_from_valid_checkout_sessions
= expected_available
```

Where consumed quantity includes orders/tickets in states accepted by the
state-machine contracts as paid, fulfillment queued, ticket issued, or partially
issued.

## Reconciliation Report

Each run must produce:

- `offer_id`
- `event_id`
- `started_at`
- `finished_at`
- `health_before`
- `health_after`
- `redis_available_before`
- `redis_available_after`
- `expected_available`
- `active_hold_count`
- `orphan_hold_count`
- `consumed_count`
- `released_count`
- `expired_count`
- `manual_review_required?`
- `anomalies`

## Repair Rules

- If Redis can be safely adjusted to expected availability, repair and report.
- If active holds are ambiguous, mark degraded/manual review; do not guess.
- If ticket issuance already happened, never add those tickets back to
  availability.
- Returning refunded/revoked tickets to saleable stock requires explicit policy
  and audit.
