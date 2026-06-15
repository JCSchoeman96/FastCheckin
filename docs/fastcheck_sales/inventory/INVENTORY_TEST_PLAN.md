# Inventory Test Plan

## Future Implementation Test Categories

- Atomic reserve success and insufficient-inventory failure.
- Duplicate reserve same idempotency key is idempotent.
- Duplicate reserve with different quantity conflicts.
- Consume active hold succeeds once.
- Duplicate consume does not double-consume.
- Release active hold increments once.
- Release consumed hold does not increment availability.
- Expiry worker skips consumed holds.
- Expiry worker removes stale zset members.
- Redis unavailable blocks new reservations.
- Redis restart forces degraded/rebuilding until reconciliation.
- Reconciliation repairs safe mismatches.
- Reconciliation marks ambiguous state degraded/manual review.
- Late verified payment after expiry re-reserves only when inventory remains.
- Late verified payment after expiry with no inventory moves to manual review.
- WhatsApp/admin/internal/future web paths all use `ReservationLedger`.

## Example RED Tests

- Controller directly decrements Redis availability.
- WhatsApp handler directly writes hold keys.
- Duplicate release increments availability twice.
- Expiry releases consumed hold.
- Checkout proceeds while health is `degraded`.

## Example GREEN Tests

- `reserve` creates hold and decrements availability atomically.
- `consume` marks hold consumed without decrementing twice.
- `release` is idempotent.
- `reconcile_offer` reports and repairs deterministic mismatch.
- Health `unknown` blocks reservation.
