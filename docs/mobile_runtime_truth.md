# Mobile Runtime Truth

This is the canonical repo note for the current Android mobile runtime truth.

## Raw Payload Truth

Raw scanned payload must currently be preserved exactly; no client normalization policy is promoted.

- Android sends the raw scanned payload as `ticket_code` unchanged today.
- There is no approved client-side normalization policy today.
- The only proven backend-side normalization today is required-field trimming in
  Phoenix validation.
- Android queues and uploads the raw captured payload as `ticket_code`.
- Android attendee sync preserves backend `ticket_code` exactly as delivered.
- Phoenix currently trims required mobile scan fields during validation.
- That trimming does not prove any broader QR normalization policy or scanned
  payload resolver for `/api/v1/mobile/*`.

## Direction Truth

Android runtime remains effectively IN-only; OUT is not a promoted successful business flow.

- Active Android UI and use cases still create `IN` scans only.
- `OUT` still exists in model and scaffolding code, but the live mobile upload
  paths reject it as not implemented.
- Phoenix validation accepting `"out"` is not the same thing as promoted
  business support.

## Ingestion Mode Truth

redis_authoritative is the target/proven path in tests and perf; legacy and shadow are fallback/migration modes; deployed production truth cannot be proven from repo code alone.

- Repo default and fallback truth today is `legacy`.
- Exercised authoritative truth today is `redis_authoritative`.
- Deployed production truth remains unproven from repo code alone.
- Repo fallback truth:
  - `config/config.exs` defaults to `:legacy`
  - `config/test.exs` defaults to `:legacy`
- Runtime override truth:
  - `config/runtime.exs` resolves `MOBILE_SCAN_INGESTION_MODE`
  - `lib/fastcheck/scans/ingestion_mode.ex` defines the supported values and
    fallback behavior
- Exercised authoritative proof:
  - `README.md`
  - `docs/mobile_scan_performance.md`
  - `test/fastcheck/scans/mobile_upload_service_test.exs`
  - `test/fastcheck_web/controllers/mobile/sync_controller_test.exs`
- Deployed production truth:
  - not provable from repo code alone because the live runtime environment is
    outside this repository

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
