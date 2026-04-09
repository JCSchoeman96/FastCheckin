# Mobile Scan Performance Runbook

This runbook covers the protocol-level k6 harness for the active mobile API contract:

- `POST /api/v1/mobile/login`
- `GET /api/v1/mobile/attendees`
- `POST /api/v1/mobile/scans`

The main entrypoint remains:

- `performance/k6/mobile_scans.js`

The harness is event-readiness focused. It now supports explicit suite families for:

- fresh-event steady state
- duplicate-heavy traffic
- auth churn
- mixed attendee sync plus scan load
- offline spike batches
- endurance soak
- abuse controls
- diagnostics
- degraded-network runs tagged through an external transport-shaping layer

The harness now treats logical device count separately from executor headroom:

- `PERF_DEVICE_COUNT` controls logical scanner identities
- `preAllocatedVUs` and `maxVUs` control k6 worker slack

That means endurance and auth-churn runs can keep `20` logical scanners while allocating more than `20` VUs to avoid dropped iterations from executor starvation.

The primary runtime target is still `POST /api/v1/mobile/scans` in `redis_authoritative` mode.

Current recorded local baselines:

- `docs/mobile_scan_performance_baseline_2026-03-19.md`
- `docs/mobile_scan_performance_baseline_2026-03-27.md`

## App-Capped Local Docker Path

Use the `perf-small` profile when you want an app-tier ceiling estimate for a `2 vCPU / 2 GB` app container without also capping Postgres or Redis.

The `perf-small` stack has two services:

- `app-perf` runs the Phoenix release in `redis_authoritative`, capped at `cpus: 2.0` and `mem_limit: 2g`
- `perf-proxy` is the only host-exposed entrypoint for capacity, mixed-load, abuse, and degraded-network runs

`app-perf` stays internal on the Docker network for measurements. The proxy strips inbound `X-Forwarded-For`, maps one logical device id to one deterministic synthetic IP in `10.250.0.0/16`, and forwards trusted client identity to Phoenix.

Start the capped stack:

```bash
docker compose up -d postgres pgbouncer redis
docker compose --profile perf-small up --build -d app-perf perf-proxy
```

Trusted perf path:

- proxy/API: `http://127.0.0.1:4100`
- health via proxy: `http://127.0.0.1:4100/api/v1/health`

This is an app-tier measurement only. It is not a full small-stack ceiling because Postgres and Redis remain unconstrained.

## Seed Deterministic Load Data

Create a dedicated event and manifest:

```bash
mix fastcheck.load.seed_mobile_event \
  --attendees 50000 \
  --credential scanner-secret \
  --ticket-prefix PERF \
  --output performance/manifests/mobile-load-event.json
```

When seeding from the host shell against the local Docker stack:

```bash
set MIX_ENV=dev
set DB_HOST=localhost
set DB_PORT=5434
set DB_PASSWORD=postgres
set ENCRYPTION_KEY=perf-small-encryption-key-perf-small-encryption-key-1234
mix ecto.migrate
mix fastcheck.load.seed_mobile_event --attendees 50000 --credential scanner-secret --ticket-prefix PERF --output performance/manifests/mobile-load-event.json
```

If the app under test is `app-perf`, the seed must use the same `ENCRYPTION_KEY` as the runtime under test. Otherwise `POST /api/v1/mobile/login` will fail with `403 invalid_credential`.

The manifest includes:

- event ID and credential
- deterministic ticket prefix and ticket count
- non-overlapping slices for baseline, business duplicates, offline burst, and soak
- invalid prefix
- replay seed and control ranges for primed duplicate traffic

## Cleanup Seeded Perf Data

Cleanup is manual. k6 runs do not remove seeded events, scan attempts, check-ins, Oban jobs, or Redis hot-state keys.

Cleanup all seeded perf events:

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

For a clean rerun after knee-finding or soak work, use a fresh cleanup and reseed before the next pass.

## Runtime Configuration

The server runtime is authoritative-only. k6 does not switch ingestion behavior per request.

Primary target:

```bash
set ENABLE_METRICS=true
mix phx.server
```

The `perf-small` Docker path already bakes in:

- `ENABLE_METRICS=true`
- `REDIS_URL=redis://redis:6379`
- `DATABASE_POOLING_MODE=pgbouncer_transaction`
- `DB_PREPARE_MODE=unnamed`
- `OBAN_NOTIFIER=pg`
- `DATABASE_SSL=false`
- trusted forwarded-identity modeling through `perf-proxy`

For capacity and endurance runs, use the proxy path only. Do not target `app-perf` directly.

Failure-injection target:

```bash
set MOBILE_SCAN_FORCE_ENQUEUE_FAILURE=true
mix phx.server
```

For a dedicated enqueue-failure recovery check, run one forced-failure instance and one normal authoritative instance against the same Postgres and Redis.

## Canonical k6 Suites

Canonical scenario keys:

- `perf_fresh_steady`
- `perf_duplicate_heavy`
- `perf_auth_churn`
- `perf_sync_scan_mixed`
- `perf_spike_batch`
- `perf_soak_endurance`
- `abuse_login`
- `abuse_scans_single_device`
- `diagnostic_enqueue_failure`
- `network_latency_degraded`
- `network_jitter_degraded`
- `network_loss_recovery`

Deprecated aliases still resolve temporarily, but they are intentionally undocumented and emit warnings in the summary output and acceptance artifacts.

## Example Runs

Use the same entrypoint for every suite:

```bash
k6 run performance/k6/mobile_scans.js ...
```

Fresh-event steady state:

```bash
k6 run performance/k6/mobile_scans.js ^
  -e MANIFEST_PATH=performance/manifests/mobile-load-event.json ^
  -e PERF_BASE_URL=http://127.0.0.1:4100 ^
  -e PERF_DEVICE_COUNT=64 ^
  -e SCENARIOS=perf_fresh_steady
```

Duplicate-heavy steady state:

```bash
k6 run performance/k6/mobile_scans.js ^
  -e MANIFEST_PATH=performance/manifests/mobile-load-event.json ^
  -e PERF_BASE_URL=http://127.0.0.1:4100 ^
  -e PERF_DEVICE_COUNT=64 ^
  -e SCENARIOS=perf_duplicate_heavy
```

Auth churn:

```bash
k6 run performance/k6/mobile_scans.js ^
  -e MANIFEST_PATH=performance/manifests/mobile-load-event.json ^
  -e PERF_BASE_URL=http://127.0.0.1:4100 ^
  -e PERF_DEVICE_COUNT=20 ^
  -e PERF_AUTH_CHURN_RATE=20 ^
  -e PERF_AUTH_CHURN_DURATION=15m ^
  -e PERF_AUTH_CHURN_PREALLOCATED_VUS=40 ^
  -e PERF_AUTH_CHURN_MAX_VUS=60 ^
  -e PERF_AUTH_CHURN_FORCE_REFRESH_INTERVAL_SECONDS=60 ^
  -e K6_ENFORCE_THRESHOLDS=true ^
  -e SCENARIOS=perf_auth_churn
```

`perf_auth_churn` deliberately induces one forced `401 -> login -> retry` recovery per device per minute by default. Use this suite to isolate login throttling and protected-route auth recovery from the normal scan-endurance path.

Mixed attendee sync plus scan load:

```bash
k6 run performance/k6/mobile_scans.js ^
  -e MANIFEST_PATH=performance/manifests/mobile-load-event.json ^
  -e PERF_BASE_URL=http://127.0.0.1:4100 ^
  -e PERF_DEVICE_COUNT=64 ^
  -e SCENARIOS=perf_sync_scan_mixed
```

The suite expands into two executors:

- `perf_sync_scan_mixed_scan`
- `perf_sync_scan_mixed_attendees`

Acceptance output reports:

- scan executor metrics
- attendee executor metrics
- one combined family verdict

Offline spike batches:

```bash
k6 run performance/k6/mobile_scans.js ^
  -e MANIFEST_PATH=performance/manifests/mobile-load-event.json ^
  -e PERF_BASE_URL=http://127.0.0.1:4100 ^
  -e PERF_DEVICE_COUNT=64 ^
  -e SCAN_BATCH_SIZE=25 ^
  -e SCENARIOS=perf_spike_batch
```

Endurance soak:

```bash
k6 run performance/k6/mobile_scans.js ^
  -e MANIFEST_PATH=performance/manifests/mobile-load-event.json ^
  -e PERF_BASE_URL=http://127.0.0.1:4100 ^
  -e PERF_DEVICE_COUNT=20 ^
  -e PERF_SOAK_ENDURANCE_RATE=20 ^
  -e PERF_SOAK_ENDURANCE_DURATION=1h ^
  -e PERF_SOAK_ENDURANCE_PREALLOCATED_VUS=40 ^
  -e PERF_SOAK_ENDURANCE_MAX_VUS=60 ^
  -e K6_ENFORCE_THRESHOLDS=true ^
  -e SCENARIOS=perf_soak_endurance
```

`perf_soak_endurance` is scan-oriented. It keeps success, replay-duplicate, business-duplicate, and invalid outcomes in the mix, but it does not deliberately induce refresh churn or attendee-sync traffic.

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

Diagnostics:
```bash
k6 run performance/k6/mobile_scans.js ^
  -e MANIFEST_PATH=performance/manifests/mobile-load-event.json ^
  -e PERF_BASE_URL=http://127.0.0.1:4101 ^
  -e PERF_DEVICE_COUNT=1 ^
  -e RECOVERY_BASE_URL=http://127.0.0.1:4000 ^
  -e SCENARIOS=diagnostic_enqueue_failure
```

## Degraded-Network Runs

`network_profile.js` is metadata only. It does not simulate latency, jitter, loss, or outage behavior inside the script.

Run degraded-network suites through an external shaping layer such as:

- `perf-proxy` behind `tc netem`
- a dedicated degradation proxy
- environment-specific transport shaping in staging or Kubernetes

Canonical degraded-network suites:

- `network_latency_degraded`
- `network_jitter_degraded`
- `network_loss_recovery`

Latency example:

```bash
k6 run performance/k6/mobile_scans.js ^
  -e MANIFEST_PATH=performance/manifests/mobile-load-event.json ^
  -e PERF_BASE_URL=http://127.0.0.1:4100 ^
  -e PERF_DEVICE_COUNT=64 ^
  -e NETWORK_PROFILE=latency ^
  -e SCENARIOS=network_latency_degraded
```

Jitter example:

```bash
k6 run performance/k6/mobile_scans.js ^
  -e MANIFEST_PATH=performance/manifests/mobile-load-event.json ^
  -e PERF_BASE_URL=http://127.0.0.1:4100 ^
  -e PERF_DEVICE_COUNT=64 ^
  -e NETWORK_PROFILE=jitter ^
  -e SCENARIOS=network_jitter_degraded
```

Loss and recovery example:

```bash
k6 run performance/k6/mobile_scans.js ^
  -e MANIFEST_PATH=performance/manifests/mobile-load-event.json ^
  -e PERF_BASE_URL=http://127.0.0.1:4100 ^
  -e PERF_DEVICE_COUNT=64 ^
  -e NETWORK_PROFILE=loss_recovery ^
  -e SCENARIOS=network_loss_recovery
```

Interpret degraded-network acceptance with extra attention to:

- auth bootstrap collapse
- refresh failure drift
- retryable failure drift
- blocked-rate distortion
- post-recovery duplicate spikes

## Distortion Gate

Do not start long soak until shorter runs meet both conditions:

- blocked or `429` scan responses stay under `2%` of total scan requests
- blocked traffic is not dominated by one logical device/source

The acceptance report includes blocked counts, blocked rate, and the top offending device ids.

## Recommended Run Order

Use this sequence for the next local validation pass:

1. Smoke and proxy-identity gate using a short `perf_fresh_steady` run through `http://127.0.0.1:4100`
2. Clean `perf_soak_endurance`
3. Isolated `perf_auth_churn`

Do not evaluate login throttling from the endurance soak. Treat login throttling as meaningful only after:

- the proxy identity gate confirms distinct synthetic IPs across logical devices
- the clean endurance soak stays scan-oriented
- the auth path is exercised in `perf_auth_churn` on its own

## Duration Guidance

- local shakeout soak: `30` to `60` minutes, only after the distortion gate passes
- perf or staging soak: minimum `120` minutes
- event-readiness endurance soak: `2` to `4` hours at a rate below the measured knee

For the current local `perf-small` baseline, the latest note still says:

- `800 req/s` is the conservative fresh-event soak target
- `1000` to `1200 req/s` should be treated as aggressive follow-up only after a fresh-event pass stays clean

## Reporting and Evidence

Each run writes these artifacts to `performance/results/` by default:

- `k6-summary-<timestamp>.json`
- `k6-acceptance-<timestamp>.json`
- `k6-acceptance-<timestamp>.md`

Acceptance artifacts include, per selected suite:

- invoked scenario key
- canonical scenario key
- alias warning flag
- suite verdict
- per-section metrics
- auth bootstrap and refresh counts
- auth refresh failure rate
- retryable failures
- dropped iterations
- VU pressure context

For `perf_sync_scan_mixed`, the report must show:

- a scan executor section
- an attendee executor section
- one combined family verdict

For `perf_auth_churn`, the report must show:

- controlled forced-refresh activity
- deterministic refresh-gate pass or fail
- refresh failure count and rate

For `perf_soak_endurance`, the report should show:

- `auth refreshes` near zero
- no deliberate auth-churn pressure
- scan-path stability interpreted separately from auth-path stability

## Observability

Enable Phoenix metrics with `ENABLE_METRICS=true`.

For the capped Docker path, validate:

- `GET http://127.0.0.1:4100/api/v1/health`
- all k6 traffic goes through the proxy base URL
- proxy response headers expose `X-Perf-Device-Id` and `X-Perf-Client-Ip`
- application logs show distributed `10.250.x.y` forwarded IPs
- bootstrapped devices in `setup_data.devices[*].synthetic_ip` are distinct across the configured logical device pool

Supporting infrastructure data during runs:

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
