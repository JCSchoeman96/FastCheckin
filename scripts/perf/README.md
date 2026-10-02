# Performance Harness

## P1-F Oban snapshot fixture

`oban_snapshot_fixture.exs` creates synthetic, PII-free `oban_jobs` rows for the later P1-F query-plan evidence phase. The scenarios implement the approved v3 future-capacity model. They are design targets and synthetic stress data, not production measurements.

Scenarios:

- `normal` models the single-node launch capacity.
- `high-pressure` models the approved peak window and queue accumulation.
- `incident` creates the synthetic backlog and terminal-history stress case.

Run the side-effect-free manifest check with a fixed UTC time. `FASTCHECK_DEV_DB_PASSWORD` is required by the development Mix config; the validation path does not start Repo or connect to PostgreSQL or Redis.

```bash
FASTCHECK_DEV_DB_PASSWORD=not-used \
mix run --no-start scripts/perf/oban_snapshot_fixture.exs -- \
  --validate-only normal --now 2026-01-01T00:00:00Z
```

Choose one scenario (`normal`, `high-pressure`, or `incident`) and supply `--now <UTC RFC3339>` on every run. Validation checks approved row counts, lifecycle invariants, concurrency limits, payload-class counts, and the canonical manifest SHA-256.

Load mode is a separate operation and is not authorized by the validation command. It requires a disposable, already migrated PostgreSQL 18 database named `fastcheck_oban_fixture`, an empty `public.oban_jobs` table, a loopback-only `OBAN_FIXTURE_DATABASE_URL`, and `P1F_OBAN_FIXTURE_ACK=disposable-local-database`. The script starts only `FastCheck.Repo`, writes directly in batches of 1,000, and does not start the Phoenix application, Oban, plugins, Redis, or business workers. Wide metadata uses deterministic, PII-free padding and PostgreSQL's default compression and TOAST behavior. The script never changes storage settings, falls back to `DATABASE_URL`, or creates or truncates a database.

When loading is separately authorized, invoke it with `mix run --no-start`; the script refuses to load if the FastCheck application or Repo is already started. Set both required fixture environment variables only for that approved local run:

```bash
OBAN_FIXTURE_DATABASE_URL="${OBAN_FIXTURE_DATABASE_URL:?set the approved loopback fixture URL}" \
P1F_OBAN_FIXTURE_ACK=disposable-local-database \
FASTCHECK_DEV_DB_PASSWORD=not-used \
mix run --no-start scripts/perf/oban_snapshot_fixture.exs -- incident \
  --now 2026-01-01T00:00:00Z --load
```

Do not use this tool with production or staging data. Fixture loading and query-plan evidence require separate authorization. Query plans are a later phase; this script does not run `EXPLAIN`.

## 1) Seed representative dataset (5000 attendees)

```bash
mix run scripts/perf/seed_perf_event.exs
```

Optional env vars:
- `FASTCHECK_PERF_ATTENDEE_COUNT` (default `5000`)
- `FASTCHECK_PERF_EVENT_NAME`
- `FASTCHECK_PERF_ENTRANCE`
- `FASTCHECK_PERF_SITE_URL`

## 2) Check-in API load harness

```bash
FASTCHECK_BASE_URL=http://localhost:4000 \
FASTCHECK_SCANNER_TOKEN=<jwt> \
FASTCHECK_TICKETS_FILE=./tickets.txt \
FASTCHECK_LOAD_COUNT=1000 \
FASTCHECK_LOAD_CONCURRENCY=25 \
mix run scripts/perf/check_in_load.exs
```

## 3) Mobile scan upload harness

```bash
FASTCHECK_BASE_URL=http://localhost:4000 \
FASTCHECK_SCANNER_TOKEN=<jwt> \
FASTCHECK_TICKETS_FILE=./tickets.txt \
FASTCHECK_BATCH_SIZE=250 \
FASTCHECK_BATCH_COUNT=4 \
FASTCHECK_BATCH_CONCURRENCY=4 \
mix run scripts/perf/mobile_sync_load.exs
```

## 4) DB tuning window helpers

Run `scripts/perf/db_tuning.sql` against your database to capture:
- top scan-related statements from `pg_stat_statements`
- `EXPLAIN (ANALYZE, BUFFERS)` plans for lock-sensitive scan queries
