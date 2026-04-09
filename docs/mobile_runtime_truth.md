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
