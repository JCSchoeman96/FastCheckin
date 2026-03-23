# Oban Boundaries After Redis-Authoritative Admission

This note documents what Oban currently owns in the Redis-authoritative mobile
scan architecture, what must remain synchronous, and what may be introduced
later only if production evidence justifies it.

D2 is a design and constraint note. It does not create queues by itself.

## Preconditions

- Runtime proof remains mandatory for any follow-up work:
  - `MOBILE_SCAN_INGESTION_MODE=redis_authoritative`
  - authoritative tests fail loudly if they drift off that mode
- The mobile scan request path remains:
  `validate -> hot-state decision -> enqueue durability -> promote results -> respond`
- Do not reintroduce per-scan durable Postgres mutation into the request path.

## Current Oban Truth

Current implemented topology:

- queue: `scan_persistence`
- worker: `FastCheck.Scans.Jobs.PersistScanBatchJob`
- enqueue site: `FastCheck.Scans.MobileUploadService.enqueue_all_required_jobs/3`
- notifier:
  - direct Postgres uses `Oban.Notifiers.Postgres`
  - `pgbouncer_transaction` resolves to `Oban.Notifiers.PG`
- retry:
  - `scan_persistence` uses `max_attempts: 10`
- durable uniqueness:
  - `scan_attempts` enforces unique `(event_id, idempotency_key)`

What `scan_persistence` currently does:

- appends durable `scan_attempts`
- projects success into attendee, check-in, and session state
- projects duplicate and payment-invalid audit rows into legacy tables

Already implemented and required to stay true:

- enqueue-before-ack gate
- retry-safe durability via `scan_attempts` uniqueness
- replay-safe duplicate audit persistence
- authoritative-mode assertions in mobile service and controller tests

Still conceptual only:

- `scan_backlog_repair`
- `scan_reconciliation`
- `scan_metrics_aggregation`
- any separate audit fan-out queue

## What Must Stay Synchronous

These must never move into Oban:

- request validation
- hot-state load and build-wait behavior
- Redis admission and idempotency decision
- business duplicate classification
- payment-invalid decision
- enqueue-before-ack gate
- result promotion to final acknowledged state
- mobile response mapping and contract shaping

Required failure semantics:

- if enqueue fails before acknowledgement, return the existing top-level request
  error
- do not acknowledge and let a background job decide acceptance later
- do not use Oban for eventual admission or duplicate truth

## Approved Async Responsibilities

### Keep `scan_persistence` as the primary durability queue

Queue and worker:

- `scan_persistence`
- `FastCheck.Scans.Jobs.PersistScanBatchJob`

Responsibilities:

- persist already-acknowledged authoritative results
- append `scan_attempts`
- run first-pass legacy projection only after durable insert succeeds

Retry and duplication rules:

- keep `max_attempts: 10`
- keep durable uniqueness as `(event_id, idempotency_key)`
- duplicate job execution must not duplicate:
  - `scan_attempts`
  - success projection
  - duplicate or payment-invalid audit rows
- keep default Oban exponential backoff unless measured backlog evidence
  justifies tuning

Failure semantics:

- worker failure is a durability incident, not a request-path incident
- request-path results are never retroactively changed by worker outcome

### Only one likely next queue: `scan_backlog_repair`

Queue and worker:

- `scan_backlog_repair`
- `FastCheck.Scans.Jobs.ScanBacklogRepairJob`

Purpose:

- repair downstream projection for already-durable `scan_attempts`
- operate only on durable identifiers such as `scan_attempts.id` or
  `(event_id, idempotency_key)`

Activation threshold:

- repeated durable-vs-projection drift after `scan_persistence` drains
- repeated repair-worthy incidents across more than one event
- or a measured backlog pattern not solved by `scan_persistence` hardening alone

Rules:

- `max_attempts: 20`
- unique job key must be the durable attempt identity
- no-op when projection is already complete
- must not accept raw mobile scan payloads
- must not re-decide admission
- must not create duplicate audit or projection side effects
- use slower exponential backoff than `scan_persistence`

### Do not split audit yet

- keep audit inside `scan_persistence` unless it measurably starves durability
  or needs an independent destination
- do not introduce a separate audit queue without a concrete downstream
  consumer or clear queue interference evidence

## Later Candidates

These are not part of the first follow-up implementation pass.

### `scan_reconciliation`

Queue and worker:

- `scan_reconciliation`
- `FastCheck.Scans.Jobs.ScanReconciliationJob`

Purpose:

- compare Redis consequences, `scan_attempts`, and projected legacy state
- operate on bounded event or time-window scopes only

Rules:

- `max_attempts: 5`
- unique by bounded reconciliation scope
- must converge safely on repeated runs

### `scan_metrics_aggregation`

Queue and worker:

- `scan_metrics_aggregation`
- `FastCheck.Scans.Jobs.ScanMetricsAggregationJob`

Purpose:

- produce non-critical metrics, anomaly summaries, or operator rollups
- source data from durable records and queue state

Rules:

- `max_attempts: 5`
- unique by aggregation window
- repeated execution must overwrite or merge deterministically

## Anti-Duplication Rules

These apply to every future async worker:

- no duplicate durable projection
- no duplicate duplicate or payment-invalid audit rows
- no duplicate reconciliation side effects
- no duplicate metrics rollups unless aggregation is explicitly idempotent by
  window

Worker guard style:

- `scan_persistence`: durable uniqueness in `scan_attempts`
- `scan_backlog_repair`: unique durable-attempt job identity plus state check
  before mutation
- `scan_reconciliation`: unique bounded-scope job identity plus convergent
  repair logic
- `scan_metrics_aggregation`: unique window identity plus overwrite or
  merge-safe writes

General rule:

- async workers operate from durable identifiers and durable facts only
- they must not reconstruct truth from request messages or replay raw mobile
  scans

## Degraded-Mode Behavior

If Redis admission remains healthy but durability falls behind:

- request-path admission does not change
- mobile result semantics do not change
- duplicate classification does not move into background processing
- the system keeps acknowledging scans only while enqueue still succeeds
- after enqueue, lag is treated as a durability or backlog incident
- operators should continue trusting request-path results, while
  ops/diagnostics surface durability lag separately

Signals that should trigger concern:

- rising `scan_persistence` queue depth
- rising oldest job age
- rising retryable count
- drain time not recovering after load
- durable `scan_attempts` growth diverging from downstream projection completion
- repeated repair or reconciliation activity on the same event scope

Policy:

- alert first
- repair second
- preserve request truth always

## Cluster-Topology Caveat

Single-node local or perf status:

- already proven for `redis_authoritative + pgbouncer_transaction +
  OBAN_NOTIFIER=pg`
- current `scan_persistence` behavior is acceptable there

Future multi-node Railway status:

- not yet proven for `Oban.Notifiers.PG`
- do not assume cross-node notifier, wake-up, or leadership behavior is solved
  from local proof alone

Promotion rule:

- no new async queue should be production-promoted on multi-node Railway until
  Oban cluster behavior is explicitly verified there

## Rollout Order And Checks

1. Keep the current topology with only `scan_persistence` active for scan
   follow-up.
2. Harden `scan_persistence` observability first.
3. Keep audit inside `scan_persistence`.
4. Add `scan_backlog_repair` only if the stated trigger criteria are met.
5. Leave reconciliation and metrics as later candidates until repair exists and
   evidence justifies them.

Required observability:

- queue depth
- available, executing, and retryable counts
- oldest job age
- drain time after perf slices
- discard count
- success vs retry rate
- durable `scan_attempts` growth
- projection lag indicators
- per-event hotspot visibility

Required tests for any D2 follow-up:

- authoritative mode assertion remains explicit
- `scan_persistence` retries stay idempotent
- duplicate job execution does not duplicate durable projection
- duplicate job execution does not duplicate duplicate or payment-invalid audit
  rows
- persistence lag does not alter mobile response semantics
- repair jobs cannot re-decide admission
- any new worker has explicit uniqueness and retry tests
- route-level mobile acceptance tests remain unchanged

## Assumptions And Defaults

- D2 stays near-term and implementation-adjacent
- current production-relevant queue remains `scan_persistence`
- next likely queue, if needed, is `scan_backlog_repair`
- audit remains inside `scan_persistence` by default
- no request-path truth moves into Oban
- multi-node Railway Oban behavior remains an explicit unproven caveat
- numeric alert thresholds are intentionally out of scope for D2
