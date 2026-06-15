# Payment After Expiry Policy

## Purpose

Define safe behavior when payment is verified after checkout or Redis hold
expiry.

## Policy

| Case | Outcome |
|---|---|
| Payment verified before hold expiry | Consume Redis hold and issue ticket through approved issuer. |
| Payment verified after hold expiry and inventory is still available | Re-reserve/consume through `ReservationLedger`, then allow issuance. |
| Payment verified after hold expiry and inventory is unavailable | Move order/payment to `manual_review`; do not issue automatically. |
| Webhook arrives after order expired | Verify payment server-side, record event, then apply this policy. |
| Duplicate payment/webhook for already-issued order | Return idempotent success; do not issue again. |
| Amount/currency/reference mismatch | Move to `manual_review`; do not issue ticket. |

## Rules

- Late verified payment must not blindly issue tickets.
- Late verified payment must not oversell inventory.
- Customer-facing messages must never deny payment after durable verified payment
  exists.
- Refund or support messaging is allowed only through approved manual-review or
  refund/revocation policy.

## Future Tests

- Late verified payment with available inventory re-reserves and issues once.
- Late verified payment with no inventory moves to manual review.
- Duplicate late webhook does not duplicate tickets.
- Customer messaging after verified payment remains truthful.
