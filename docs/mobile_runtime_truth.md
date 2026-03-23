# Redis-Authoritative Mobile Runtime Truth

This note records the current backend truth for the promoted mobile runtime.

## Mode Truth

Do not collapse these into one statement:

- repo default:
  - `config/config.exs` still defaults mobile scan ingestion to `:legacy`
- runtime override:
  - `config/runtime.exs` resolves `MOBILE_SCAN_INGESTION_MODE`
- exercised authoritative proof:
  - local perf docs and authoritative tests are explicitly pinned to
    `:redis_authoritative`
- deployed production truth:
  - not proven by repo code alone

Document `:redis_authoritative` as the target runtime mode and the mode used by
the documented authoritative test/perf paths, not as an unqualified production
fact.

## Current Mobile Request Path

The promoted Android contract remains:

- `POST /api/v1/mobile/login`
- `GET /api/v1/mobile/attendees`
- `POST /api/v1/mobile/scans`

For `POST /api/v1/mobile/scans`, the authoritative path is:

`validate -> hot-state decision -> enqueue durability -> promote results -> respond`

Operationally that means:

1. Android captures and queues locally first
2. auto-flush is the normal upload path; manual flush remains fallback/debug
3. backend validates each scan
4. Redis hot state performs admission and idempotency decisions
5. durability jobs are enqueued before acknowledgement
6. acknowledged results are promoted in hot state
7. durable Postgres projection happens asynchronously afterward through Oban

No per-scan durable Postgres mutation belongs in the request path before
acknowledgement.

## Contract Truth

Stable mobile scan item envelope:

- `idempotency_key`
- `status`
- `message`

Additive only:

- optional authoritative `reason_code`

Current operator-visible semantics:

- `success`
- `duplicate`
- `error`

`reason_code` is additive refinement only and must not replace `status` without
versioning.

## Migration Boundaries

Backend modes:

- `:redis_authoritative`:
  - target hot path for mobile scans
- `:legacy`:
  - fallback/migration mode only
- `:shadow`:
  - transitional verification mode only

Android targets:

- Android does not choose among these modes
- Android must not treat `:legacy` or `:shadow` as promoted runtime targets
- Android must continue using only `/api/v1/mobile/*`

## Runtime-Truth Checklist

- active Android routes are only `/api/v1/mobile/login`,
  `/api/v1/mobile/attendees`, and `/api/v1/mobile/scans`
- authoritative request path stays synchronous through acknowledgement
- durable Postgres projection stays async after acknowledgement
- richer result taxonomy is additive only
- `direction = "out"` is still not a successful mobile business flow
- future device/session routes are not current Android dependencies
