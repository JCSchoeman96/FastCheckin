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

## VS-04B RED and GREEN Expectations

RED until implemented:

- No canonical `ReservationLedger` API contract assertions.
- No explicit error-family assertions for lock/idempotency/degraded responses.
- No concurrency race coverage for last-ticket reservation and expiry/consume
  overlap.

GREEN after implementation:

- `reserve`/`consume`/`release`/`expire_due_holds` implement atomic outcomes.
- Duplicate operations are idempotent and return stable results.
- Degraded/unavailable/reconciliation-required states fail closed.
- No operation drives inventory negative.

## VS-04C RED and GREEN Expectations

RED until implemented:

- No deterministic reconciliation report/assertions.
- No proof that durable state wins when Redis diverges.

GREEN after implementation:

- `reconcile_offer/1` deterministically repairs safe mismatches.
- Ambiguous inventory remains degraded/manual-review.
- Reconciliation gates checkout until healthy state restoration.

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
- No PII or raw provider payloads in inventory keys/events/logs.
