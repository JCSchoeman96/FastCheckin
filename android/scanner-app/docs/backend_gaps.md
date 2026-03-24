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
- Raw scanned payload must currently be preserved exactly; no client normalization policy is promoted.
- Phoenix currently trims required mobile scan fields during validation, but no
  broader QR normalization or scanned-payload mapping policy is promoted.
- Android runtime remains effectively IN-only; OUT is not a promoted successful business flow.
- redis_authoritative is the target/proven path in tests and perf; legacy and shadow are fallback/migration modes; deployed production truth cannot be proven from repo code alone.

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
