# Backend Gaps

## Active Gap List

- Android runtime still authenticates with event-scoped JWT login instead of a
  hybrid device/session model.
- `/api/v1/mobile/scans` returns `status` plus free-form `message` instead of a
  richer machine-readable decision taxonomy.
- **Mobile scan upload result taxonomy is status-only today:**
  - `status` is one of: `success`, `duplicate`, `error`
  - reasons are currently only in free-form `message` text and are **not stable** for client-side classification
  - Android must not infer “Invalid / not found”, “Payment invalid”, “Wrong event”, etc. from `message` until the backend provides a stable `reason_code` field
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
