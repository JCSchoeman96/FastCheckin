# Redis Key Structure

## Required Keys

| Key | Redis type | Purpose | TTL / expiry | Owner |
|---|---|---|---|---|
| `sales:offer:{offer_id}:meta` | hash | Config snapshot: event_id, quantity, sales window, version. | Rebuilt with offer initialization. | `ReservationLedger` |
| `sales:offer:{offer_id}:available` | string integer or hash field | Hot available quantity counter. | No short TTL during active sale. | `ReservationLedger` |
| `sales:offer:{offer_id}:holds` | sorted set | Hold expiry ledger; member = public_reference/hold key, score = expiry timestamp. | Members expire through worker/ledger logic. | `ReservationLedger` |
| `sales:hold:{public_reference}` | hash | Hold detail: offer_id, quantity, order ref, status, idempotency key, expires_at. | At least through hold lifecycle and recovery window. | `ReservationLedger` |
| `sales:order:{public_reference}:lock` | string | Per-order short lock. | Short TTL only. | `ReservationLedger` |
| `sales:inventory:events:{offer_id}` | list or stream-like list | Optional operational audit for reserve/consume/release/expire/reconcile. | Bounded retention. | `ReservationLedger` |
| `sales:inventory:health:{offer_id}` | hash/string | Health state: healthy, rebuilding, degraded, closed. | Maintained while offer is sellable. | `ReservationLedger` |
| `sales:event:{event_id}:offers` | string/json/hash | Warm offer display cache. | Recommended 30 minutes. | Sales read/cache layer |

## Optional Future Seat-Specific Patterns

Reserved seating is out of scope for the first general-admission MVP, but these
patterns are reserved for future work:

- `sales:seatmap:{event_id}:{offer_id}`
- `sales:seatbits:{event_id}:{offer_id}`
- `sales:seat_holds:{event_id}:{offer_id}`

Do not implement seat maps unless the event model explicitly requires it.

## Rules

- Do not put PII directly into Redis key names.
- Do not mutate these keys from controllers, LiveViews, WhatsApp handlers, or
  Ash resources.
- Key writes go through `ReservationLedger`.
