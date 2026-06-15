# Hold TTL and Expiry Policy

## Required Decisions

Defaults for first implementation:

- Public/WhatsApp checkout hold TTL: 10-15 minutes.
- Admin-assisted hold TTL: same as public by default unless explicitly
  configured later.
- Internal pilot TTL: may be longer, but must not be used for public sales.
- Future web checkout TTL: same as public by default.

## Rules

- `CheckoutSession.expires_at` must align with Redis hold expiry.
- Redis zset score is the operational expiry authority.
- Postgres `CheckoutSession` is durable intent and audit.
- Expiry worker reconciles both layers.
- Customer messages must be truthful when payment is pending or late.
- Close-to-expiry payment starts remain subject to payment-after-expiry policy.

## Expiry Outcomes

| Case | Outcome |
|---|---|
| Hold expires before payment | Release unconsumed hold and expire session/order as allowed. |
| Hold expires after consume | Skip release; consumed inventory remains sold. |
| Payment verifies after expiry and inventory available | Re-reserve/consume through `ReservationLedger`. |
| Payment verifies after expiry and inventory unavailable | Move to manual review/refund path. |
