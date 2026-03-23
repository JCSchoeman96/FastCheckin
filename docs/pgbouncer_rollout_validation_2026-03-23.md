# PgBouncer Rollout Validation 2026-03-23

This note records the first local Docker validation pass for the PgBouncer rollout support added for the `:redis_authoritative` mobile scan backend.

Primary evidence artifact:

- `performance/results/pgbouncer-rollout-report-2026-03-23T17-15-37Z.json`

## Mode And Topology Proof

Validated runtime:

- `MOBILE_SCAN_INGESTION_MODE=redis_authoritative`
- `DATABASE_URL=ecto://postgres:postgres@pgbouncer:5432/fastcheck_prod`
- `DATABASE_POOLING_MODE=pgbouncer_transaction`
- `OBAN_NOTIFIER=pg`

Validated local topology:

- `app-perf -> pgbouncer -> postgres`
- `perf-proxy -> app-perf`
- Redis remained the request-path admission authority
- release migrations stayed on direct Postgres through `MIGRATION_DATABASE_URL`

## Important Local Fix

The initial local PgBouncer cutover failed before load validation because the Docker PgBouncer image defaulted to `auth_type = md5` while the local Postgres 18 container used `scram-sha-256`.

The local perf topology was corrected by setting:

- `AUTH_TYPE=scram-sha-256`

in [docker-compose.yml](/mnt/c/headless_projects/PETAL_blueprint_project/FastCheckin/docker-compose.yml).

That was a local pooler/auth compatibility issue, not a mobile ingestion path regression.

## Slice Results

### Same-Ticket Replay Burst

Targeted same-ticket, same-idempotency burst against `/api/v1/mobile/scans`:

- `12` requests
- `1` `success`
- `11` `duplicate`
- `11` `reason_code = replay_duplicate`
- latency:
  - min `27.3 ms`
  - avg `119.1 ms`
  - p95 `130.9 ms`
  - max `131.8 ms`

Interpretation:

- final replay duplicate semantics stayed truthful under PgBouncer
- no generic error drift

### Same-Ticket Business-Duplicate Burst

Targeted same-ticket, different-idempotency burst against `/api/v1/mobile/scans`:

- `12` requests
- `1` `success`
- `11` `error`
- `11` `reason_code = business_duplicate`
- latency:
  - min `16.8 ms`
  - avg `21.1 ms`
  - p95 `24.2 ms`
  - max `24.2 ms`

Interpretation:

- same-ticket different-idempotency behavior remained a business duplicate
- no drift into generic retryable failure

### Duplicate-Heavy Slice

Authoritative harness slice:

- scenario: `capacity_baseline`
- rate: `20 req/s`
- duration: `30 s`
- requests: `676`
- blocked rate: `0`
- HTTP failed rate: `0`
- result mix:
  - success `225`
  - replay duplicate `30`
  - business duplicate `390`
  - invalid `31`
  - retryable failure `0`
- latency:
  - p95 `9.25 ms`

Database and pool observations:

- repo queue time delta avg: `0.0266 ms`
- repo query time delta avg: `0.7378 ms`
- PgBouncer `cl_waiting`: `0`
- PgBouncer server state after slice:
  - `sv_idle = 2`
  - `sv_used = 17`
- Postgres `numbackends`: `20`
- `scan_persistence` jobs after slice:
  - available `0`
  - executing `0`
  - retryable `0`

Interpretation:

- PgBouncer reduced connection fan-out to a stable `20` upstream backends in this local topology
- no request-path failure or duplicate-taxonomy regression was observed
- no active durability backlog remained after the slice

### Short Stability Slice

Authoritative harness slice:

- scenario: `capacity_soak`
- rate: `20 req/s`
- duration: `60 s`
- requests: `1201`
- blocked rate: `0`
- HTTP failed rate: `0`
- result mix:
  - success `147`
  - replay duplicate `121`
  - business duplicate `903`
  - invalid `30`
  - retryable failure `0`
- latency:
  - p95 `8.17 ms`

Database and pool observations:

- repo queue time delta avg: `0.0230 ms`
- repo query time delta avg: `0.6927 ms`
- PgBouncer `cl_waiting`: `0`
- PgBouncer server state after slice:
  - `sv_idle = 2`
  - `sv_used = 17`
- Postgres `numbackends`: `20`
- `scan_persistence` jobs after slice:
  - available `0`
  - executing `0`
  - retryable `0`

Interpretation:

- short steady-state behavior remained stable through PgBouncer
- request-path latency stayed low
- no visible durability drain problem appeared in this local validation window

## Oban Caveat

This local validation used:

- `OBAN_NOTIFIER=pg`
- no `DNS_CLUSTER_QUERY`

That is acceptable for this single-node local Docker proof and matches the startup warning already emitted by the app.

What this run does prove:

- queue dispatch worked
- jobs were persisted
- no `available`, `executing`, or `retryable` `scan_persistence` backlog remained after the measured windows

What this run does not prove:

- multi-node Railway cluster leadership behavior
- multi-node notifier fan-out semantics

Those still require staged or production-topology verification before a full Railway cutover.

## Bottom Line

Local Docker validation is now operationally stronger than the original D1 implementation-only state:

- the exercised path was explicitly `:redis_authoritative`
- PgBouncer transaction pooling was actually in the path
- same-ticket replay and business-duplicate semantics remained stable
- duplicate-heavy and short stability slices showed:
  - `0` blocked responses
  - `0` HTTP failures
  - low request latency
  - low Repo queue time
  - stable upstream Postgres backend count
  - no active `scan_persistence` backlog at the end of the observation windows

Remaining rollout gap:

- verify `Oban.Notifiers.PG` behavior and cluster semantics in the real Railway topology before treating PgBouncer as production-proven.
