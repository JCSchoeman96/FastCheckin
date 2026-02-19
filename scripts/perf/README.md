# Performance Harness

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
