-- Launch tuning window helpers for FastCheck

-- Enable once per database (requires superuser):
-- CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

-- Top scan-related statements by total execution time
SELECT
  query,
  calls,
  total_exec_time,
  mean_exec_time,
  rows,
  shared_blks_hit,
  shared_blks_read,
  temp_blks_read,
  temp_blks_written
FROM pg_stat_statements
WHERE query ILIKE '%attendees%'
   OR query ILIKE '%check_in_sessions%'
   OR query ILIKE '%mobile_idempotency_log%'
ORDER BY total_exec_time DESC
LIMIT 30;

-- Example explain: attendee lookup + row lock
EXPLAIN (ANALYZE, BUFFERS)
SELECT *
FROM attendees
WHERE event_id = 1 AND ticket_code = 'PERF-1-00001'
FOR UPDATE NOWAIT;

-- Example explain: active session lookup (should hit partial index)
EXPLAIN (ANALYZE, BUFFERS)
SELECT *
FROM check_in_sessions
WHERE event_id = 1
  AND attendee_id = 1
  AND exit_time IS NULL
FOR UPDATE NOWAIT;

-- Example explain: aggregate scanner stats query
EXPLAIN (ANALYZE, BUFFERS)
SELECT
  count(id) AS total,
  sum(CASE WHEN checked_in_at IS NOT NULL THEN 1 ELSE 0 END) AS checked_in
FROM attendees
WHERE event_id = 1;
