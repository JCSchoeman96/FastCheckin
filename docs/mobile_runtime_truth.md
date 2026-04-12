# Mobile Runtime Truth

This is the canonical repo note for the current Android mobile runtime truth.

## Raw Payload Truth

Android canonicalizes ticket identity by trimming proven scanner boundary whitespace before local lookup, replay suppression, queueing, and upload; structured QR parsing is not promoted.

- Contract tests are the source of truth for the accepted trim vectors.
- Android source adapters still emit raw capture strings.
- Android queues and uploads the canonicalized `ticket_code`.
- Android attendee sync canonicalizes backend `ticket_code` before local
  storage.
- Phoenix currently trims required mobile scan fields during validation for the
  covered contract cases.
- That does not promote any broader QR normalization policy or scanned payload
  resolver for `/api/v1/mobile/*`.

## Direction Truth

Android runtime remains effectively IN-only; OUT is not a promoted successful business flow.

- Active Android UI and use cases still create `IN` scans only.
- `OUT` still exists in model and scaffolding code, but the live mobile upload
  paths reject it as not implemented.
- Phoenix validation accepting `"out"` is not the same thing as promoted
  business support.

## Ingestion Mode Truth

redis_authoritative is now the only supported mobile upload runtime path in this repo; legacy and shadow are no longer supported runtime modes.

- `config/config.exs`, `config/runtime.exs`, and `config/test.exs` no longer expose runtime mode switching for mobile scan upload.
- `lib/fastcheck/scans/mobile_upload_service.ex` runs only the authoritative path.
- Authoritative proof lives in:
  - `docs/mobile_scan_performance.md`
  - `test/fastcheck/scans/mobile_upload_service_test.exs`
  - `test/fastcheck_web/controllers/mobile/sync_controller_test.exs`

## Current Promoted Request Path

The promoted Android mobile contract remains:

- `POST /api/v1/mobile/login`
- `GET /api/v1/mobile/attendees`
- `POST /api/v1/mobile/scans`

## Attendee sync down (`GET /api/v1/mobile/attendees`)

**Parallel `limit` (one exact sentence):** The numeric `limit` query parameter applies **in parallel** — the **attendees** sub-stream and the **invalidations** sub-stream are **independently capped** (each returns at most `limit` rows per response). It is **not** one shared row budget across both JSON arrays.

Single atomic JSON per successful response. The client keeps **three** checkpoints after a successful apply:

1. **`event_sync_version`** — monotonic version for the event (store after apply).
2. **`next_cursor`** — opaque cursor for the **active attendees** sub-stream only (stable order: `updated_at`, `id`). Omit or pass through on the next request as `cursor` while continuing to drain attendees.
3. **`invalidations_checkpoint`** — pass the next request as **`since_invalidation_id`** to page **invalidation events** (`id` ascending).

**Query parameters**

| Parameter | Required | Notes |
|-----------|----------|--------|
| `limit` | **Yes** | Positive integer, maximum **500**. |
| `since` | No | ISO8601; invalid `since` falls back to full sync (existing behaviour). |
| `since_invalidation_id` | No | Non-negative integer; default **0** (last `invalidations_checkpoint`). |
| `cursor` | No | Opaque; pages **attendees** only. |

**Successful JSON `data` fields** include `server_time`, `attendees`, `invalidations`, `invalidations_checkpoint`, `event_sync_version`, `next_cursor`, `sync_type`, `count`.

**HTTP 400 — exact `error.code` values** (envelope: `data: null`, `error: { code, message }`)

| `error.code` | Meaning |
|----------------|---------|
| `invalid_since` | `since` is not valid ISO8601. |
| `invalid_since_invalidation_id` | `since_invalidation_id` is not a non-negative integer. |
| `missing_limit` | `limit` omitted. |
| `invalid_limit` | `limit` not a positive integer. |
| `limit_too_large` | `limit` greater than 500. |
| `invalid_cursor` | `cursor` cannot be decoded. |

**Pagination rule:** each of the attendees list and the invalidations list is capped at **`limit`** rows per response (independent caps). The attendees stream includes **active** tickets only; revoked upstream tickets appear as **invalidation** rows, not as attendee rows.

**Catch-up loop (recommended):** repeat `GET` until both **`next_cursor`** is absent (attendees drained for the current `since` scope) **and** either invalidations are empty **or** the last response returned fewer than `limit` invalidation rows (no backlog at the invalidation cap). If a response returns **`limit`** invalidation rows, issue another request with the same attendee `cursor` but an updated **`since_invalidation_id`** from **`invalidations_checkpoint`** until the invalidation stream is drained, then continue attendee paging as needed.

**Apply order on the client (per response):** apply **`invalidations`** (e.g. delete local row by `ticket_code`) **before** merging **`attendees`** for that response so a tombstone is not overwritten by a stale upsert.

Do not infer ticket removal from incremental attendee pages alone; apply **`invalidations`** explicitly (e.g. delete local cache row by `ticket_code`).

For `POST /api/v1/mobile/scans`, the authoritative path is:

`validate -> hot-state decision -> enqueue durability -> promote results -> respond`

Operationally that means:

1. Android captures and queues locally first.
2. Android flushes via the existing mobile scan upload endpoint.
3. Phoenix validates each scan.
4. Redis hot state performs admission and idempotency decisions in the
   authoritative path.
5. Durability jobs are enqueued before acknowledgement.
6. Acknowledged hot-state results are promoted before the response returns.
7. Durable Postgres projection happens asynchronously afterward through Oban.
