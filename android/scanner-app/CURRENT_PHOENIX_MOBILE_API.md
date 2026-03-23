# Current Phoenix Mobile API Contract

This is the current Android runtime contract. Treat it as the only promoted
mobile API until the backend explicitly replaces it.

## Runtime Truth

The repo now has three different truths that must not be conflated:

- **Code default / fallback truth**:
  - `config/runtime.exs` still resolves `MOBILE_SCAN_INGESTION_MODE` to
    `:legacy` when no runtime override is present.
- **Exercised/runtime-proof truth**:
  - the local perf path and authoritative controller/service tests are pinned to
    `:redis_authoritative`
  - those authoritative tests fail loudly if they drift off that mode
- **Android runtime truth**:
  - Android targets only `/api/v1/mobile/*`
  - scans are queued locally first
  - backend admission is authoritative in hot state
  - durability is queued before acknowledgement
  - durable Postgres projection happens asynchronously afterward

`:redis_authoritative` is the target runtime mode for the documented hot path.
`:legacy` and `:shadow` remain backend migration/fallback modes and are not
Android targets.

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

## End-To-End Runtime Sequence

The implemented operational sequence is:

1. operator logs in with `event_id` and credential
2. app stores the event JWT securely and syncs attendees from
   `GET /api/v1/mobile/attendees`
3. scanner captures decode into local queue admission only
4. auto-flush is the normal upload path; manual flush remains a fallback/debug
   control
5. backend validates the batch items
6. backend hot state performs admission and idempotency decisions
7. backend queues durability work before acknowledgement
8. backend acknowledges the batch only after enqueue succeeds
9. backend durability worker projects results into Postgres asynchronously
10. Android diagnostics and persisted flush outcomes update from later
    repository/Room state, not from camera-time capture alone

The authoritative request path remains:

`validate -> hot-state decision -> enqueue durability -> promote results -> respond`

No per-scan durable Postgres mutation belongs in the request path before
acknowledgement.

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

- login is event-scoped
- the JWT is reused for attendee sync and scan upload until expiry
- JWT must be stored in secure storage only
- non-secret session metadata such as `event_id`, `event_name`, and expiry can
  be stored separately
- login credentials are not persisted for silent re-authentication

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

- sync attendees only through this endpoint
- the server remains the business-rule authority; the attendee cache is a local
  mirror only
- invalid `since` still falls back to full sync on the backend
- preserve backend `ticket_code` exactly; do not add client normalization policy

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

- always send `{ "scans": [...] }`
- never send `{ "batches": ... }`
- the stable per-item envelope remains:
  - `idempotency_key`
  - `status`
  - `message`
- the backend may add optional `reason_code` for authoritative outcomes, but
  Android must continue to key runtime behavior off `status`
- `direction = "out"` is still not a successful mobile business flow
- the server performs the business-rule decision; client runtime queues,
  replay-suppresses, and uploads only

## Batch Limit

- Android enforces a maximum batch size of `50` scans per request
- the auto-flush coordinator currently runs bounded flush loops with batches of
  `25`, while repository/worker entry points still support `50`
- this remains an Android operating limit, not a backend-promoted batch-size
  contract

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

- any item returned in `data.results` is terminal-complete for that
  `idempotency_key`
- any queued item missing from `data.results` after HTTP `200` is retained for
  retry
- additive `reason_code` must not replace `status` semantics unless the API is
  deliberately versioned

## Stable vs Additive Response Semantics

Stable contract fields Android may rely on:

- login envelope: `data`, `error`
- login payload: `token`, `event_id`, `event_name`, `expires_in`
- attendee sync payload: `server_time`, `attendees`, `count`, `sync_type`
- scan upload payload: `results`, `processed`
- scan upload result fields: `idempotency_key`, `status`, `message`
- auth error HTTP `401` from the mobile auth pipeline

Additive only:

- optional authoritative `reason_code`
- richer backend taxonomy that does not replace the existing envelope

Current client rule:

- classify queue behavior by `status`
- do not parse `message` for unproven causes

## JWT Expiry During Background Flush

- the JWT bearer token is stored in Keystore-backed secure storage
- event/session metadata is stored separately from the token
- the credential used for `/api/v1/mobile/login` is not stored for background
  re-login
- if a flush receives HTTP `401`, the worker/coordinator must stop flushing,
  preserve the queue, mark auth as expired in app state, and require manual
  re-authentication

## Partial Success Semantics

- `/api/v1/mobile/scans` returns HTTP `200` with a per-item `results` array and
  `processed` count
- Android reconciles outcomes by `idempotency_key`, not by request order alone
- returned items are removed from the queue and written to replay cache
- queued items absent from the response are preserved and retried later

## Runtime-Truth Checklist

- active Android routes are only:
  - `/api/v1/mobile/login`
  - `/api/v1/mobile/attendees`
  - `/api/v1/mobile/scans`
- authoritative request path is:
  `validate -> hot-state decision -> enqueue durability -> promote results -> respond`
- no per-scan durable Postgres mutation happens before acknowledgement
- richer result taxonomy is additive only
- `:legacy` and `:shadow` are backend modes, not Android targets

## Known Backend Limitations

- auth is still event JWT login, not hybrid device/session identity
- gate/device/offline-package models are not active runtime dependencies
- offline approval is not a full local business-rule engine
- `direction = "out"` is not yet a successful mobile business flow
