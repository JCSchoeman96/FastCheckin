# Backend Gaps

## Active Gap List

- Android runtime still authenticates with event-scoped JWT login instead of a
  hybrid device/session model.
- `/api/v1/mobile/scans` now preserves the stable per-item envelope
  `idempotency_key`, `status`, `message`, with optional authoritative-only
  `reason_code` values for `replay_duplicate`, `business_duplicate`, and
  `payment_invalid`.
- **Mobile scan upload result taxonomy is still intentionally narrow:**
  - `status` remains one of: `success`, `duplicate`, `error`
  - Android must continue to key behavior off `status`; `reason_code` is additive
  - Android must not infer "Invalid / not found", "Wrong event", or other unproven causes from `message`
  - `replay_duplicate` is emitted only for final replay duplicates
  - concurrent same-idempotency uploads may still surface without `replay_duplicate`
    while the original authoritative result is not yet final
- Partial success is not described by explicit per-item retry flags, so the
  client must interpret missing result items as retryable.
- The exact QR payload normalization contract is unresolved: it is not yet
  confirmed that raw scanned payload always equals backend `ticket_code`.
- Runtime mobile direction support is effectively `IN` only.

## Future Routes Are Inactive

The following backend surfaces are future-facing only and are not part of the
active Android runtime contract:

- `/api/v1/device_sessions`
- `/api/v1/check_ins`
- `/api/v1/check_ins/flush`
- `/api/v1/events/:event_id/config`
- `/api/v1/events/:event_id/package`
- `/api/v1/events/:event_id/health`
- gate/device/offline-package entities

Android docs, runtime code, and tests must not treat them as current
dependencies.
