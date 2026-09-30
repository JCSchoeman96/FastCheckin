# Redis Postgres Reconciliation Policy

## Durable Facts

Reconciliation uses:

- `TicketOffer.configured_quantity_available` or `initial_quantity`.
- Order statuses.
- CheckoutSession statuses and `expires_at`.
- OrderLine quantities.
- TicketIssue issued/revoked states.
- PaymentAttempt `verified_success` and manual-review states.
- Refund evidence, lifecycle state, Order/PaymentAttempt ownership, and
  inventory resolution.

Durable precedence rule:

- Postgres/Ash durable state is authoritative when Redis disagrees.
- Redis is repaired to match durable state or marked degraded/manual-review when
  ambiguity remains.

## General Admission Formula

```text
configured_quantity
- sold_quantity_from_paid_fulfillment_orders_and_refunded_orders
- active_hold_quantity_from_valid_checkout_sessions
= expected_available
```

Paid, fulfillment-queued, ticket-issued, partially-issued, and refunded
Orders count as sold unless the Order has one exact completed Refund with
`released_unconsumed` resolution. Reconciliation accepts that release only
when the Refund links to the Order's Paystack PaymentAttempt, both records show
the exact full amount and currency, provider evidence is `processed` with a
non-empty RRN and timestamp, revocation completed, the PaymentAttempt is
`refunded`, exactly one positive OrderLine matches the Order's total and
currency for the offer being counted, and no issued TicketIssue remains. A
malformed or mismatched completed Refund does not release capacity and requires
manual review.

A Refund in `inventory_pending` or a manual-review state, a
`retained_consumed` resolution, and a legacy refunded Order without a matching
Refund remain sold and unavailable.

Only `completed` plus `released_unconsumed` may add capacity back to
`expected_available`. Reconciliation never infers that result from
`Order = refunded` alone.

## Refund disposition rules

| Durable facts | Availability | Report |
|---|---|---|
| Refund `completed` with `released_unconsumed` | Capacity may become available after exact authority checks. | Count in `released_count`. |
| Refund `completed` with `retained_consumed` | Keep sold and unavailable. | Count in `retained_consumed_count`. |
| Refund `inventory_pending` | Keep sold and unavailable. | `refund_inventory_resolution_pending`. |
| Refund `inventory_manual_review` | Keep sold and unavailable; require manual review. | `refund_inventory_resolution_manual_review`. |
| Refund `revocation_manual_review` | Keep the underlying durable quantity unavailable; do not infer release. | `refund_revocation_manual_review`. |
| Refunded Order with no matching Refund | Keep sold and unavailable; do not infer provider evidence. | `legacy_refund_without_provider_evidence`. |

`evidence_recorded` and `revocation_complete` do not authorize inventory
availability. They precede financial finalization and must be resolved through
the Refund lifecycle first.

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
- `released_unconsumed_count`
- `retained_consumed_count`
- `refund_inventory_pending_count`
- `refund_inventory_manual_review_count`
- `expired_count`
- `manual_review_required?`
- `anomalies`

## Repair Rules

- If Redis can be safely adjusted to expected availability, repair and report.
- If active holds are ambiguous, mark degraded/manual review; do not guess.
- If ticket issuance already happened, never add those tickets back to
  availability.
- Increase availability for a refunded Order only when the matching Refund is
  `completed` with `released_unconsumed` resolution. Keep retained, pending,
  manual-review, and legacy refunded quantities unavailable.
- Anomalies involving refund evidence or inventory resolution set
  `manual_review_required?` and prevent an upward repair until the durable
  facts are resolved.
- Reconciliation must increment inventory revision and stamp reconciliation time.

P1-C does not reclaim consumed inventory. Browser admission, asynchronous
mobile database persistence, and the Android local-first queue/overlay do not
provide one global unused-ticket proof. Future consumed-capacity reclaim is
blocked on unified admission/usage authority and fencing under
`FastCheckin-52n8`.
