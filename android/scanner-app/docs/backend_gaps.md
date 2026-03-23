# Backend Gaps

## Active Gap List

- Android runtime still authenticates with event-scoped JWT login instead of a
  hybrid device/session model.
- Repo config still falls back to `:legacy` unless runtime overrides it.
  Authoritative tests and local perf docs are pinned to `:redis_authoritative`,
  but deployed production truth still requires explicit runtime verification.
- `/api/v1/mobile/scans` preserves the stable per-item envelope
  `idempotency_key`, `status`, `message`, with optional authoritative-only
  `reason_code` values for `replay_duplicate`, `business_duplicate`, and
  `payment_invalid`.
- Mobile scan upload result taxonomy is intentionally narrow:
  - `status` remains one of `success`, `duplicate`, `error`
  - Android must continue to key behavior off `status`
  - `reason_code` is additive
  - Android must not infer invalid/not-found or other unproven causes from
    `message`
  - `replay_duplicate` is emitted only for final replay duplicates
  - concurrent same-idempotency uploads may still surface without
    `replay_duplicate` while the original authoritative result is not yet final
- Partial success is not described by explicit per-item retry flags, so the
  client must interpret missing result items as retryable.
- Backend admission is authoritative in hot state, but durable Postgres
  projection still happens asynchronously after acknowledgement.
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
