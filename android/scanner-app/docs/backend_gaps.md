# Backend Gaps

## Active Gap List

- Android runtime still authenticates with event-scoped JWT login instead of a
  hybrid device/session model.
- `/api/v1/mobile/scans` returns `status` plus free-form `message` instead of a
  richer machine-readable decision taxonomy.
- Mobile scan upload result taxonomy is status-only today:
  - `status` is one of `success`, `duplicate`, `error`
  - Android must classify queue outcomes from `status` and missing result rows,
    not from parsing `message`
- Partial success is not described by explicit per-item retry flags, so Android
  must interpret missing result items as retryable.
- Android canonicalizes ticket identity by trimming proven scanner boundary
  whitespace before local lookup, replay suppression, queueing, and upload;
  structured QR parsing is not promoted.
- Contract tests are the source of truth for the accepted trim vectors.
- Android runtime remains effectively IN-only; OUT is not a promoted successful business flow.
- redis_authoritative is now the only supported mobile upload runtime path in this repo; legacy and shadow are no longer supported runtime modes.

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
