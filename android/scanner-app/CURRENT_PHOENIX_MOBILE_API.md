# Current Phoenix Mobile API Contract

This Android app must treat the current Phoenix mobile API as the only promoted
runtime contract until the backend explicitly replaces it. Future backend
scanner routes such as `/api/v1/device_sessions`, `/api/v1/check_ins`,
`/api/v1/check_ins/flush`, config/package/health endpoints, gates, devices,
and offline package concepts are inactive for Android runtime and must remain
future-facing placeholders only.

## Runtime Scope

Active Android runtime dependencies:

- `POST /api/v1/mobile/login`
- `GET /api/v1/mobile/attendees`
- `POST /api/v1/mobile/scans`

Inactive for Android runtime:

- `/api/v1/device_sessions`
- `/api/v1/check_ins`
- `/api/v1/check_ins/flush`
- `/api/v1/events/:event_id/config`
- `/api/v1/events/:event_id/package`
- `/api/v1/events/:event_id/health`
- gate/device/offline-package runtime entities

## Login

Endpoint: `POST /api/v1/mobile/login`

Request:

```json
{
  "event_id": 123,
  "credential": "scanner-secret"
}
```

Success response:

```json
{
  "data": {
    "token": "jwt-token",
    "event_id": 123,
    "event_name": "Event Name",
    "expires_in": 86400
  },
  "error": null
}
```

Runtime notes:

- Login is event-scoped.
- The returned JWT is the active bearer token for attendee sync and scan upload.
- JWT must be stored in secure storage only.
- Non-secret session metadata such as `event_id`, `event_name`, and expiry can
  be stored separately from the token.
- Login credentials are not persisted for silent re-authentication.

## Attendee Sync

Endpoint: `GET /api/v1/mobile/attendees`

Headers:

```text
Authorization: Bearer <jwt>
```

Optional query:

```text
since=<ISO8601 timestamp>
```

Success response:

```json
{
  "data": {
    "server_time": "2026-03-12T10:00:00Z",
    "attendees": [
      {
        "id": 1,
        "event_id": 123,
        "ticket_code": "TEST001",
        "first_name": "John",
        "last_name": "Doe",
        "email": "john@example.com",
        "ticket_type": "VIP",
        "allowed_checkins": 1,
        "checkins_remaining": 1,
        "payment_status": "completed",
        "is_currently_inside": false,
        "checked_in_at": null,
        "checked_out_at": null,
        "updated_at": "2026-03-12T09:55:00Z"
      }
    ],
    "count": 1,
    "sync_type": "full"
  },
  "error": null
}
```

Runtime notes:

- Sync attendees only through this endpoint.
- The server is the business-rule authority; attendee cache is a local mirror,
  not the source of truth.
- Invalid `since` falls back to full sync on the backend today.
- Android stores backend `ticket_code` exactly as delivered in attendee sync
  until a new contract explicitly promotes a broader normalization policy.

## Scan Upload

Endpoint: `POST /api/v1/mobile/scans`

Headers:

```text
Authorization: Bearer <jwt>
```

Request:

```json
{
  "scans": [
    {
      "idempotency_key": "uuid-or-stable-key",
      "ticket_code": "TEST001",
      "direction": "in",
      "scanned_at": "2026-03-12T10:01:00Z",
      "entrance_name": "Main Gate",
      "operator_name": "Scanner 1"
    }
  ]
}
```

Success response:

```json
{
  "data": {
    "results": [
      {
        "idempotency_key": "uuid-or-stable-key",
        "status": "success",
        "message": "Check-in successful"
      }
    ],
    "processed": 1
  },
  "error": null
}
```

Runtime notes:

- Always send `{ "scans": [...] }`.
- Never send `{ "batches": ... }`.
- Raw scanned payload must currently be preserved exactly; no client normalization policy is promoted.
- Phoenix currently trims required mobile scan fields during validation. That is
  backend-side input handling, not a promoted QR normalization policy.
- Android runtime remains effectively IN-only; OUT is not a promoted successful business flow.
- The server performs the actual business-rule decision; client runtime should
  queue, replay-suppress, and upload, not simulate approval logic locally.

## Batch Limit

- Android enforces a maximum batch size of `50` scans per request.
- This is a client-side operating limit for predictable WorkManager flushes.
- The current backend does not publish a stricter explicit limit yet, so the
  client must treat `50` as its own safe ceiling until the backend contract
  changes.

## Error Classes

Request-level retryable errors:

- network failure / no connectivity
- timeout / transport failure
- HTTP `5xx`
- missing per-item results in an otherwise successful `/api/v1/mobile/scans`
  response

Auth-blocking errors:

- HTTP `401`
- invalid or expired JWT reported by the mobile auth plug

Terminal item outcomes from `/api/v1/mobile/scans`:

- `status = "success"`
- `status = "duplicate"`
- `status = "error"` when the backend has already produced a final item result

Current Android interpretation rules:

- item classification is driven by `status` plus whether a queued
  `idempotency_key` is missing from `data.results`
- `message` may be shown or stored for diagnostics, but it must not be parsed
  into business truth
- any item returned in `data.results` is treated as terminal-complete for that
  `idempotency_key`
- any queued item missing from `data.results` after HTTP `200` is retained for
  retry

## JWT Expiry During Background Flush

- The JWT bearer token is stored in Keystore-backed secure storage.
- Event/session metadata is stored separately from the token.
- The credential used for `/api/v1/mobile/login` is not stored for background
  re-login.
- If a WorkManager flush receives HTTP `401`, the worker must stop flushing,
  preserve the queue, mark auth as expired in app state, and require operator
  re-authentication before more uploads.

## Partial Success Semantics

- `/api/v1/mobile/scans` returns HTTP `200` with a per-item `results` array and
  `processed` count.
- Android must reconcile results by `idempotency_key`, not by request ordering
  alone.
- Returned items are removed from the queue and written to replay cache.
- Queued items absent from the response are preserved and retried later.

## Stable Contract Fields

Android may rely on:

- login envelope: `data`, `error`
- login payload: `token`, `event_id`, `event_name`, `expires_in`
- attendee sync payload: `server_time`, `attendees`, `count`, `sync_type`
- attendee row fields currently emitted by the backend JSON serializer
- scan upload payload: `results`, `processed`
- scan upload result fields: `idempotency_key`, `status`, `message`
- auth error HTTP `401` from the mobile auth pipeline

## Backend Ingestion Mode Note

- Repo fallback truth remains `legacy` in `config/config.exs` and `config/test.exs`.
- redis_authoritative is the target/proven path in tests and perf.
- `legacy` and `shadow` remain fallback or migration modes.
- Deployed production truth cannot be proven from repo code alone.

## Known Backend Limitations

- Auth is still event JWT login, not hybrid device/session identity.
- Gate/device/offline package models are not active runtime dependencies yet.
- Offline approval is not a full local business-rule engine; the client should
  treat uploads and responses as authoritative.
- Scan upload responses return `status` + `message`, not a richer decision
  envelope yet.
