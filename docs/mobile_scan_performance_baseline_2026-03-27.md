# Mobile Scan Performance Baseline 2026-03-27

This note records the latest verified local app-tier baseline for the `redis_authoritative` mobile scan path behind `POST /api/v1/mobile/scans`.

Environment:

- local Docker perf path
- `app-perf` capped at `2 vCPU / 2 GB RAM`
- Postgres and Redis uncapped
- trusted perf proxy on `http://127.0.0.1:4100`
- deterministic seeded event data
- per-device token pool plus per-device synthetic proxy IPs
- fresh cleanup before reseeding and fresh cleanup after the runs

This is a harness-valid local baseline, not a full-stack or production ceiling.

## Summary

- Full repo verification was green before the perf pass:
  - `mix precommit`
  - Android unit tests
  - Android debug assemble
- Initial auth bootstrap failure was traced to a seed/runtime encryption mismatch, not a scan-path regression:
  - host seed used the dev fallback encryption key
  - `app-perf` used its fixed perf `ENCRYPTION_KEY`
  - result was `403 invalid_credential` on mobile login until the event was reseeded with the perf key
- After reseeding with the perf key, the authoritative path exercised cleanly.

## Verified Runs

### Smoke validation

- `capacity_smoke`
  - auth bootstrap succeeded for the device pool
  - proxy identity headers were preserved
  - result mix included success, replay duplicate, business duplicate, and invalid outcomes as expected

### Short clean stress

- `60 req/s` for `60s`
  - `2650` scan requests
  - `0` blocked responses
  - `0` auth failures
  - `0` HTTP failures
  - `p95` about `9.94 ms`

- `400 req/s` for `60s`
  - `15247` scan requests
  - `0` blocked responses
  - `0` auth failures
  - `0` HTTP failures
  - `p95` about `13.0 ms`

- `800 req/s` for `45s`
  - `29240` scan requests
  - `0` blocked responses
  - `0` auth failures
  - `0` HTTP failures
  - `p95` about `96.7 ms`

### Knee-finding bracket

- `1200 req/s` for `45s`
  - `40105` scan requests
  - `0` blocked responses
  - `0` auth failures
  - `0` HTTP failures
  - `p95` about `6.4 ms`
  - this run followed a heavier run on the same seeded event and was replay-heavy, so it is best treated as transport confirmation, not a pristine fresh-event business-mix sample

- `1600 req/s` for `45s`
  - `46060` scan requests
  - `0` blocked responses
  - `0` auth failures
  - HTTP failure rate about `0.00048`
  - repeated transport-level `EOF` failures on `POST /api/v1/mobile/scans`
  - `p95` about `2208.9 ms`
  - k6 reported VU pressure and crossed the configured latency threshold

## Current Knee Estimate

The first clear degradation signal for this local `perf-small` path appeared at about `1600 req/s`.

Interpretation:

- `800 req/s` is a clean local stress point
- `1200 req/s` did not show transport failure in the bracket run, but should be rechecked on a fresh seeded event before treating it as a clean soak baseline
- `1600 req/s` is beyond the comfortable local admission envelope for this setup

Practical baseline guidance:

- conservative local soak target: `800 req/s`
- aggressive local soak target: `1000-1200 req/s` only after a fresh-event validation pass
- do not treat `1600 req/s` as a sustainable local target for this app-capped profile

## Thresholds And Failure Signals

With `K6_ENFORCE_THRESHOLDS=true`, the current capacity thresholds are:

- `http_req_duration p(95) < 750 ms`
- `http_req_duration p(99) < 1500 ms`
- `auth_failures < 1`
- blocked-rate `< 2%`

The `1600 req/s` run crossed the latency threshold because `p95` rose above `2200 ms`.

The observed `EOF` failures were transport-level request failures, not handled business responses. k6 opened the scan upload request and the connection closed before a complete HTTP response was read. In this local stack, that is the first clear overload signal.

## Cleanup Verification

After the knee-finding runs, cleanup was run and verified:

- seeded perf event removed from Postgres
- seeded attendees removed from Postgres
- related `scan_attempts`, `check_ins`, and `scan_persistence` Oban jobs removed
- Redis DB flushed for the local perf stack

That means this baseline does not leave residual perf fixtures in the local runtime after cleanup.

## What Is Proven

- the authoritative `redis_authoritative` mobile scan path still behaves cleanly under substantial local stress
- the local app-capped perf path is comfortably below the knee at `800 req/s`
- the first observed degradation signal appears around `1600 req/s`
- the cleanup tooling is sufficient to return the local perf database and Redis state to empty after the run
- host-side seeding must use the same `ENCRYPTION_KEY` as the runtime under test

## What Is Not Proven

- this is not a production capacity claim
- this is not a full-stack ceiling because Postgres and Redis are not capped in the same way as `app-perf`
- the `1200 req/s` bracket run should be repeated on a fresh event before treating it as a clean long-soak baseline
- no long soak was run in this 2026-03-27 pass

## Next Step

Next useful follow-up:

- reseed a fresh event
- run `capacity_soak` at `800 req/s` for `30-60 minutes`
- if that remains clean, repeat a fresh-event soak at `1000` or `1200 req/s`
