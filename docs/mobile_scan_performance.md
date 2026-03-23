# Mobile Scan Performance Runbook

This runbook is for protocol-level load testing of the active mobile API contract:

- `POST /api/v1/mobile/login`
- `GET /api/v1/mobile/attendees`
- `POST /api/v1/mobile/scans`

The primary performance target is `POST /api/v1/mobile/scans` running with `MOBILE_SCAN_INGESTION_MODE=redis_authoritative`.

This performance target assumes the current authoritative runtime path:

`validate -> hot-state decision -> enqueue durability -> promote results -> respond`

Admission remains synchronous through acknowledgement. Durable Postgres
projection happens asynchronously afterward through `scan_persistence`.

Current recorded local baseline:

- `docs/mobile_scan_performance_baseline_2026-03-19.md`

## App-Capped Local Docker Path

Use the `perf-small` profile when you want an app-tier ceiling estimate for a 2 vCPU / 2 GB app container without also capping Postgres or Redis.

The `perf-small` stack now has two services:

- `app-perf` runs the Phoenix release in `redis_authoritative`, capped at `cpus: 2.0` and `mem_limit: 2g`
- `perf-proxy` is the only host-exposed entrypoint for capacity and abuse-control runs

For PgBouncer verification, `app-perf` talks to the `pgbouncer` service in transaction mode while `MIGRATION_DATABASE_URL` stays pointed at direct Postgres for release migrations.

`app-perf` stays internal on the Docker network for capacity measurements. The proxy strips inbound `X-Forwarded-For`, maps one logical device id to one deterministic synthetic IP in `10.250.0.0/16`, and forwards the trusted client identity to Phoenix.

Start the capped stack:

```bash
docker compose up -d postgres pgbouncer redis
docker compose --profile perf-small up --build -d app-perf perf-proxy
```

The trusted perf path exposes:

- proxy/API: `http://127.0.0.1:4100`
- health via proxy: `http://127.0.0.1:4100/api/v1/health`

This is an app-tier measurement only. It does not represent a full small-stack ceiling because Postgres and Redis remain unconstrained.

The current repo wiring does not expose a separate Prometheus scrape HTTP endpoint from `app-perf`, so there is no extra metrics port to publish or validate in this pass.

On Docker Desktop and WSL, make sure the Docker VM itself has more than 2 GB RAM and enough CPU headroom. Otherwise the host VM becomes the bottleneck and the `app-perf` container cap stops being meaningful.

## Seed Deterministic Load Data

Create a dedicated event and manifest:

```bash
mix fastcheck.load.seed_mobile_event \
  --attendees 50000 \
  --credential scanner-secret \
  --ticket-prefix PERF \
  --output performance/manifests/mobile-load-event.json
```

When seeding against the local Docker stack from the host shell, point your local Mix environment at the Compose Postgres port:

```bash
set MIX_ENV=dev
set DB_HOST=localhost
set DB_PORT=5434
set DB_PASSWORD=postgres
mix ecto.migrate
mix fastcheck.load.seed_mobile_event --attendees 50000 --credential scanner-secret --ticket-prefix PERF --output performance/manifests/mobile-load-event.json
```

The manifest includes:

- event ID and credential
- deterministic ticket prefix and ticket count
- non-overlapping slices for baseline, business duplicates, offline burst, and soak
- invalid prefix
- replay seed and control ranges for primed duplicate traffic

## Cleanup Seeded Perf Data

Keep the `performance/results/` JSON artifacts if you want to preserve run evidence. The cleanup task removes only the seeded mobile perf data from Postgres and Redis.

Cleanup all marker-matched perf events plus their related rows:

```bash
mix fastcheck.load.cleanup_mobile_event
```

Cleanup one seeded event from a manifest:

```bash
mix fastcheck.load.cleanup_mobile_event --manifest performance/manifests/mobile-load-event.json
```

Cleanup one seeded event and flush the current Redis DB for the local perf stack:

```bash
mix fastcheck.load.cleanup_mobile_event --event-id 123 --flush-redis
```

The cleanup task deletes, in order:

- `scan_persistence` Oban jobs tied to the seeded event
- `mobile_idempotency_log`
- `scan_attempts`
- `check_ins`
- `attendees`
- the seeded `events` row
- Redis hot-state keys for the event across namespaces, or the full current Redis DB when `--flush-redis` is used

## Runtime Configuration

Mode selection is server-side. k6 does not switch ingestion modes per request.

Primary target:

```bash
set MOBILE_SCAN_INGESTION_MODE=redis_authoritative
set ENABLE_METRICS=true
mix phx.server
```

The `perf-small` Docker path already bakes in:

- `MOBILE_SCAN_INGESTION_MODE=redis_authoritative`
- `ENABLE_METRICS=true`
- `REDIS_URL=redis://redis:6379`
- `DATABASE_POOLING_MODE=pgbouncer_transaction`
- `DB_PREPARE_MODE=unnamed`
- `OBAN_NOTIFIER=pg`
- `DATABASE_SSL=false`
- trusted forwarded-identity modeling through `perf-proxy`

For capacity runs, do not target `app-perf` directly. Use the proxy path only.

Optional rollback-confidence run:

```bash
set MOBILE_SCAN_INGESTION_MODE=legacy
mix phx.server
```

Failure-injection target:

```bash
set MOBILE_SCAN_INGESTION_MODE=redis_authoritative
set MOBILE_SCAN_FORCE_ENQUEUE_FAILURE=true
mix phx.server
```

For a full enqueue-failure recovery check, run two app instances against the same Postgres and Redis:

- one instance with `MOBILE_SCAN_FORCE_ENQUEUE_FAILURE=true`
- one normal `redis_authoritative` instance on a different port

## k6 Runs

Capacity smoke:

```bash
k6 run performance/k6/mobile_scans.js ^
  -e MANIFEST_PATH=performance/manifests/mobile-load-event.json ^
  -e PERF_BASE_URL=http://127.0.0.1:4100 ^
  -e PERF_DEVICE_COUNT=32 ^
  -e SCENARIOS=capacity_smoke
```

Capacity baseline:

```bash
k6 run performance/k6/mobile_scans.js ^
  -e MANIFEST_PATH=performance/manifests/mobile-load-event.json ^
  -e PERF_BASE_URL=http://127.0.0.1:4100 ^
  -e PERF_DEVICE_COUNT=64 ^
  -e SCENARIOS=capacity_baseline
```

Capacity stress and spike:

```bash
k6 run performance/k6/mobile_scans.js -e MANIFEST_PATH=performance/manifests/mobile-load-event.json -e PERF_BASE_URL=http://127.0.0.1:4100 -e PERF_DEVICE_COUNT=64 -e SCENARIOS=capacity_stress
k6 run performance/k6/mobile_scans.js -e MANIFEST_PATH=performance/manifests/mobile-load-event.json -e PERF_BASE_URL=http://127.0.0.1:4100 -e PERF_DEVICE_COUNT=64 -e SCENARIOS=capacity_spike -e SCAN_BATCH_SIZE=25
```

Abuse-control:

```bash
k6 run performance/k6/mobile_scans.js ^
  -e MANIFEST_PATH=performance/manifests/mobile-load-event.json ^
  -e PERF_BASE_URL=http://127.0.0.1:4100 ^
  -e PERF_DEVICE_COUNT=1 ^
  -e SCENARIOS=abuse_login

k6 run performance/k6/mobile_scans.js ^
  -e MANIFEST_PATH=performance/manifests/mobile-load-event.json ^
  -e PERF_BASE_URL=http://127.0.0.1:4100 ^
  -e PERF_DEVICE_COUNT=1 ^
  -e SCENARIOS=abuse_scans_single_device
```

Optional diagnostics:

```bash
k6 run performance/k6/mobile_scans.js ^
  -e MANIFEST_PATH=performance/manifests/mobile-load-event.json ^
  -e PERF_BASE_URL=http://127.0.0.1:4100 ^
  -e PERF_DEVICE_COUNT=1 ^
  -e SCENARIOS=legacy_smoke

k6 run performance/k6/mobile_scans.js ^
  -e MANIFEST_PATH=performance/manifests/mobile-load-event.json ^
  -e PERF_BASE_URL=http://127.0.0.1:4101 ^
  -e PERF_DEVICE_COUNT=1 ^
  -e RECOVERY_BASE_URL=http://127.0.0.1:4000 ^
  -e SCENARIOS=enqueue_failure
```

## Expected Scenario Mix

Capacity suite:

- `capacity_smoke`
- `capacity_baseline`
- `capacity_stress`
- `capacity_spike`
- `capacity_soak` after the distortion gate passes

Abuse-control suite:

- `abuse_login`
- `abuse_scans_single_device`

Online scenarios classify results into:

- success
- idempotency replay duplicate
- business duplicate
- invalid
- retryable failure
- auth failure

These categories describe authoritative request-path outcomes. They do not mean
durable projection has already completed at acknowledgement time.

Capacity runs use a deterministic device pool:

- one logical device id per VU for the run
- one device-local token per logical device
- one stable proxy-assigned synthetic IP per logical device

Shared-token behavior is no longer the capacity default.

Offline spike scenarios send deterministic batches from the offline-burst slice.

## Distortion Gate

Do not start soak until short `capacity_stress` meets both of these conditions:

- blocked or `429` scan responses stay under `2%` of total capacity scan requests
- blocked traffic is not dominated by one device/source

The k6 capacity summary reports total blocked counts plus the top offending device ids so the gate is measurable without relying on manual log inspection.

## Duration Guidance

- Local shakeout soak: 30 to 60 minutes, only after the distortion gate passes
- Perf/staging soak: minimum 120 minutes, extend to 180 minutes if the environment remains stable

## Observability

Enable Phoenix metrics with `ENABLE_METRICS=true`.

For the capped Docker path, verify these before treating a run as valid:

- `GET http://127.0.0.1:4100/api/v1/health`
- `POST /api/v1/mobile/scans` through the same proxy base URL used by k6
- proxy response headers show `X-Perf-Device-Id` and `X-Perf-Client-Ip`
- app logs show distributed `10.250.x.y` forwarded IPs during `capacity_smoke`

The current `app-perf` runtime does not expose a separate scrape endpoint, so observability for this local pass comes from:

- k6 summaries in `performance/results/`
- application logs
- Postgres `pg_stat_*` and Oban queue queries
- Redis `INFO`

Primary application metrics already exposed by the repo:

- Phoenix request latency and request counts
- `fastcheck.mobile_sync.batch.duration.duration_ms`
- repo query time and queue time
- VM memory and run queue metrics

Collect supporting infrastructure data during runs:

Postgres:

```sql
select count(*) as scan_persistence_jobs,
       count(*) filter (where state = 'available') as available_jobs,
       count(*) filter (where state = 'executing') as executing_jobs,
       count(*) filter (where state = 'retryable') as retryable_jobs
from oban_jobs
where queue = 'scan_persistence';

select datname, numbackends, xact_commit, xact_rollback
from pg_stat_database
where datname like 'fastcheck%';

select wait_event_type, wait_event, state, count(*)
from pg_stat_activity
where datname like 'fastcheck%'
group by wait_event_type, wait_event, state;
```

Redis:

```bash
redis-cli -u redis://localhost:6380 INFO memory
redis-cli -u redis://localhost:6380 INFO stats
```

## Reporting

Each k6 run writes a JSON summary to `performance/results/` by default.

The acceptance report for `redis_authoritative` should include:

- separate capacity and abuse-control sections
- sustainable request rate
- p95 and p99 latency
- HTTP failure rate
- categorized result mix
- blocked/`429` counts and blocked-rate distortion status
- top offending device ids when blocked traffic occurs
- Oban `scan_persistence` queue depth and lag
- PgBouncer `SHOW POOLS` and `SHOW STATS` output when the perf slice is routed through the pooler
- Redis memory and error signals
- Postgres queue time, connections, and lock pressure
- auth-refresh behavior
- offline burst behavior
- enqueue-failure recovery behavior, when the dedicated failure-injection run is performed

For PgBouncer rollout validation, re-run the same authoritative harness through the pooler and compare:

- same-ticket burst validation slice
- duplicate-heavy slice
- short steady-state or stability slice
- Repo queue time
- PgBouncer pool stats
- upstream Postgres connection counts
- Oban `scan_persistence` backlog and drain behavior
