# Inventory Master Contract

## Principle

Redis owns hot operational inventory during active sales. Postgres/Ash owns
durable sales intent, orders, checkout sessions, payments, issued-ticket audit,
and recovery source data.

## Channels Covered

This policy applies to:

- WhatsApp sales.
- Admin-assisted sales.
- Internal pilot sales.
- Future web checkout sales.

## Non-Negotiable Rules

- No checkout may bypass `ReservationLedger`.
- No WhatsApp flow may bypass `ReservationLedger`.
- No admin-assisted sale may bypass `ReservationLedger` unless a documented
  manual override exists and is audited.
- No future web checkout may bypass `ReservationLedger`.
- No ticket may be issued merely because Postgres says an order exists.
- No ticket may be issued after hold expiry unless payment-after-expiry recovery
  re-reserves inventory or moves the order to manual review.
- No Redis-unhealthy sale may continue accepting reservations.

## Standard Operation Result Shape

Future operations should return structured results containing:

- `status`
- `offer_id`
- `order_public_reference`
- `quantity`
- `available_after`
- `hold_key`
- `expires_at`
- `idempotency_key`
- `reason`
- `correlation_id`

Result categories:

- `:ok` with structured data.
- `:error` with machine-readable reason.
- idempotent success for duplicate safe retries.
- manual-review-required result where human intervention is needed.
