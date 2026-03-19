# Mobile Scan Performance Baseline 2026-03-19

This note records the first clean local app-tier baseline for the `redis_authoritative` mobile scan path behind `POST /api/v1/mobile/scans`.

Environment:

- local Docker perf path
- `app-perf` capped at `2 vCPU / 2 GB RAM`
- Postgres and Redis uncapped
- trusted perf proxy on `http://127.0.0.1:4100`
- deterministic seeded event data
- per-device token pool plus per-device synthetic proxy IPs

This is a harness-valid local baseline, not a full-stack or staging ceiling.

## Baseline Summary

- `capacity_smoke` was clean
  - zero blocked scan responses
  - zero auth failures
  - distributed device/token/proxy identity worked as intended
- Clean breakpoint ladder:
  - `60 req/s`
  - `120 req/s`
  - `180 req/s`
  - `240 req/s`
  - `360 req/s`
  - `480 req/s`
- First visible knee signal:
  - `600 req/s`
  - still zero blocked responses and zero auth failures
  - but `p95` latency rose to about `61 ms`
  - dropped iterations appeared
  - k6 had to scale VUs much harder to maintain the arrival rate
- Short sustained check:
  - `420 req/s` for `10 minutes`
  - zero blocked responses
  - zero auth failures
  - `p95` drifted to about `113 ms`
  - k6 hit the configured VU ceiling
- Longer local soak:
  - `300 req/s` for `2 hours`
  - zero blocked responses
  - zero auth failures
  - zero auth refreshes
  - `p95` latency was about `15.01 ms`
  - HTTP failed rate was about `0.000405`
  - the abuse-distortion gate stayed clean for the full run
  - the durability path accumulated a large Oban backlog by the end of the run

Interpretation:

- the corrected harness is now measuring scan ingestion rather than auth churn or single-source abuse controls
- the local capped app tier stayed clean through `480 req/s`
- `600 req/s` is the first stage that showed clear latency and scheduling pressure
- `420 req/s` is too close to the knee to treat as a meaningful long soak baseline, even though it did not error
- `300 req/s` is now a demonstrated local 2-hour soak point for the app-tier admission path
- the main follow-up concern from the 2-hour soak is durability backlog, not abuse-control distortion or auth churn

## Recorded Runs

- `capacity_smoke`
  - `performance/results/k6-summary-2026-03-19T11-15-09-167Z.json`
- `60 req/s`
  - `performance/results/k6-summary-2026-03-19T11-16-52-917Z.json`
- `120 req/s`
  - `performance/results/k6-summary-2026-03-19T11-18-15-312Z.json`
- `180 req/s`
  - `performance/results/k6-summary-2026-03-19T11-21-11-763Z.json`
- `240 req/s`
  - `performance/results/k6-summary-2026-03-19T11-22-37-140Z.json`
- `360 req/s`
  - `performance/results/k6-summary-2026-03-19T11-23-54-192Z.json`
- `600 req/s`
  - `performance/results/k6-summary-2026-03-19T11-25-11-669Z.json`
- `480 req/s`
  - `performance/results/k6-summary-2026-03-19T11-26-38-347Z.json`
- `420 req/s` for `10 minutes`
  - `performance/results/k6-summary-2026-03-19T11-37-27-826Z.json`
- `300 req/s` for `2 hours`
  - `performance/results/k6-summary-soak-2026-03-19T16-49-22.json`

## What Is Proven

- the auth strategy no longer distorts capacity runs
- the capacity suite no longer collapses into single-source abuse control
- the trusted proxy plus per-device token model is functioning
- abuse-control behavior is measured separately from capacity behavior
- the local capped app tier handled a short clean ladder through `480 req/s`
- the local capped app tier sustained `300 req/s` for `2 hours` with zero blocked responses and zero auth failures

## What Is Not Proven

- no `120+ minute` perf/staging soak has been completed yet
- this is not a whole-stack ceiling
- this is not a production capacity claim
- the 2-hour local soak does not prove that the durability path is fully caught up under equivalent whole-stack constraints

## Next Step

Next useful follow-up:

- record the 2-hour local soak as the current local app-tier baseline
- inspect and quantify durability backlog drain time after the soak
- repeat the soak in perf/staging for a meaningful environment-sized result
