# PgBouncer Rollout For Redis-Authoritative FastCheckin

This note covers PgBouncer rollout for the current Railway/Phoenix/Postgres deployment after the move to `:redis_authoritative` mobile ingestion.

## Preconditions

- Verify mobile scan upload is running on the authoritative path from boot logs or deployed config before rollout.
- Keep authoritative tests pinned to the authoritative path and fail loudly if they drift.
- Keep the mobile scan request path unchanged:
  `validate -> hot-state decision -> enqueue durability -> promote results -> respond`
- Do not reintroduce per-scan durable Postgres mutation before acknowledgement.

## Target Topology

- Phoenix app service -> PgBouncer service -> Railway Postgres service
- Redis remains separate and keeps admission and duplicate classification authoritative
- Keep a direct Postgres URL alongside the PgBouncer URL for:
  - release migrations
  - admin access
  - rollback

## Pooling Mode

- Primary target: `transaction`
- Start the PgBouncer path with `prepare: :unnamed` unless named prepares are explicitly verified safe for the deployed PgBouncer/Postgrex/Ecto combination.
- Keep `DATABASE_POOLING_MODE=pgbouncer_transaction` visible in runtime config and boot logs.

## Phoenix, Ecto, And Oban Assumptions To Verify

- `FastCheck.Repo` is the shared Repo for Phoenix, Ecto, and Oban.
- `PersistScanBatchJob` and `Persistence.persist_batch/1` remain the main database-pressure path after acknowledgement.
- `Oban.Notifiers.Postgres` is not safe behind PgBouncer transaction pooling.
- Primary compatibility target is `Oban.Notifiers.PG`, but it must be verified in the real Railway topology before cutover.
- If notifier or cluster verification fails, abort the shared-Repo PgBouncer rollout and keep the app on direct Postgres. Do not introduce a second Repo as part of this rollout.

## Prepared Statement And Session Caveats

- Transaction pooling is incompatible with session-affine behavior such as:
  - LISTEN/NOTIFY
  - advisory-lock-dependent flows
  - temp tables
  - persistent session `SET` assumptions
- Keep migrations on direct Postgres even after app traffic moves through PgBouncer.
- `/api/v1/health` should stay DB-backed as a readiness/dependency check.
- `/api/v1/live` should stay process-only and must not depend on Repo reachability.

## Pool Sizing Guidance

Start from current app defaults and size for async durability and background load, not scanner request rate alone.

- App Repo `POOL_SIZE`: start at `20`
- PgBouncer `pool_mode`: `transaction`
- PgBouncer `default_pool_size`: start at `15`
- PgBouncer `min_pool_size`: `5`
- PgBouncer `reserve_pool_size`: `5`
- PgBouncer `reserve_pool_timeout`: `3`
- PgBouncer `max_client_conn`: start at `100` for one app service
- PgBouncer `server_idle_timeout`: `600`
- PgBouncer `server_lifetime`: `3600`

Keep total upstream Postgres sessions comfortably below the Railway Postgres limit and leave headroom for admin sessions, migrations, and incident access.

## Rollout Steps

1. Verify Railway production is actually running `:redis_authoritative`.
2. Provision PgBouncer as a separate Railway service.
3. Keep direct Postgres env vars available.
4. Point `DATABASE_URL` at PgBouncer and keep `MIGRATION_DATABASE_URL` pointed at direct Postgres.
5. Start with the rollout-safe prepare mode and the verified Oban notifier choice.
6. Verify Oban notifier, queue wake-up, dispatch, and leadership behavior under the PgBouncer topology in perf or staging before any production cutover.
7. If Oban verification fails, abort the shared-Repo PgBouncer rollout rather than adding a partial workaround.
8. Cut over in perf or staging first, then production.

## Rollback Steps

1. Repoint the app from PgBouncer back to direct Postgres.
2. Leave Redis-authoritative mobile ingestion unchanged.
3. Keep request-path semantics unchanged.
4. Use `/api/v1/live`, `/api/v1/health`, and app logs to confirm recovery.

## Verification Checklist

Before rollout:

- Confirm production mode is `:redis_authoritative`
- Capture Repo queue time and query count
- Capture `pg_stat_activity` connection counts
- Capture Oban queue depth and error rates
- Capture a pre-rollout authoritative perf baseline

After rollout:

- `/api/v1/live` stays healthy
- `/api/v1/health` stays healthy through PgBouncer
- No spike in 5xx, auth failures, `durability_enqueue_failed`, `scan_result_promotion_failed`, or database connection errors
- Repo queue time and upstream Postgres connection count are lower or flatter under the same perf slice
- PgBouncer `SHOW POOLS` / `SHOW STATS` confirm connection collapse
- Oban `scan_persistence` backlog and drain behavior are improved or at least not worse
- Mobile request-path result mix stays unchanged

Re-run the existing authoritative perf slices through PgBouncer with the same harness and compare:

- same-ticket burst validation slice
- duplicate-heavy slice
- short steady-state or stability slice
- Repo queue time
- PgBouncer pool stats
- upstream Postgres connection counts
- Oban `scan_persistence` backlog and drain behavior

## What PgBouncer Will Improve

- Phoenix/Ecto connection churn
- upstream Postgres session pressure
- database checkout pressure from async durability and background work
- stability during durability backlog spikes

## What PgBouncer Will Not Improve

- Redis hot-state cold-load or build-lock behavior
- duplicate classification or `reason_code` semantics
- enqueue-before-ack logic
- result promotion semantics
- request-path scan admission truthfulness
- legacy ticket-row lock behavior
