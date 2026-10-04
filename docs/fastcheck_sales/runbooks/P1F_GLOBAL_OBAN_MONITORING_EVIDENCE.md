# P1-F Global Oban Monitoring Evidence

## Status

```text
P1F_QUERY_PLAN_EVIDENCE=PASS
P1F_RUNBOOK_REHEARSAL=PASS
P1F_GLOBAL_OBAN_BLOCKER=CLEARED
P1E_INGRESS_BLOCKER=OPEN
```

P1-F completion does not clear P1-E or any environment-specific launch checklist
item.

## Approved Monitoring Contract

`/dashboard/system/workers` is the approved global, read-only Oban monitoring
source. Access uses the server-owned global monitoring username allowlist. It is
not Event-scoped. `/dashboard/sales/ops` reports Event-attributable Sales data
and is not a global backlog source.

## Query-plan Evidence

The corrected active aggregate uses
`WHERE state IN ('available', 'executing', 'retryable', 'scheduled')`.
Representative plans used the existing index path in
normal conditions at about 16 shared blocks, and the existing bitmap/index path
under high pressure at about 4,059 shared blocks. For the incident case, the
planner-selected sequential scan was accepted because active-row selectivity was
high. No new index or migration was required. The correction merged in PR #498
at `d22b41209b01e2d363ce76ae885a1c54d938fbce`.

## Operational Rehearsal

The rehearsal ran against `d22b41209b01e2d363ce76ae885a1c54d938fbce` with
PostgreSQL 18.6 and Redis 7.4.8.

- Unauthenticated access redirected; authenticated non-allowlisted access
  returned 403; an allowlisted global admin received 200.
- Healthy monitoring reported `Current`, a snapshot no older than 30 seconds,
  and `distribution=shared`.
- During Redis unavailability, monitoring remained `Current` with
  `distribution=coordination_degraded`; the operator escalated and did not
  assume workers had stopped. Redis recovery restored `Current` and `shared`.
- During PostgreSQL unavailability, monitoring reported `Stale` at about 34.5
  seconds and `Unavailable` at about 70.5 seconds. Recovery restored `Current`
  and `shared`.
- All configured queues, critical queues, and the `Unexpected queues` aggregate
  were visible. The page exposed no raw job payloads and allowed no job or queue
  mutation.
- No ad-hoc SQL or worker restart was used as a monitoring response. Fixture
  state stayed unchanged, and Oban execution was disabled during the rehearsal.

## Prometheus Scrape Verification

PR #499 (`5da3657834cd9ee3af679168348828b826470db7`) added a dedicated Bandit
listener bound to `127.0.0.1:METRICS_PORT`. `GET /metrics` returned 200 with
`text/plain; version=0.0.4; charset=utf-8`; `POST /metrics` returned 404; and
the public Phoenix `APP_PORT` did not expose `/metrics`. The accepted global
Oban metric families and configured queue labels were visible. For multi-node
views, use `max without(instance)` and never sum replicated global gauges.

## Accepted Repository State

PR #500 merged at `a2cfdba0eca6fb0890d1a6a4c835c84b071c4593`, tree
`ba2a89d56e49506208d3fc0465468228f628584b`. That exact tree passed the
candidate production-path smoke: PERF configuration loaded, app health and a
real collector cycle passed, metrics returned 200 with the exact content type,
the P1-F gauge families and configured queue labels were visible, freshness was
1 with age 0.0 seconds, and the listener remained loopback-only. The public app
did not expose metrics, `POST /metrics` returned 404, and no external provider
calls occurred. The reviewed merge tree matched the smoke-tested candidate
tree, so no additional scrape rerun was needed for gate closure.

## Remaining Independent Blockers

P1-E ingress remains open. Launch operators must still verify live worker
processing, dashboard reachability, current queue contents, no unexpected live
backlog, provider readiness, and owner signoff for the actual environment.
