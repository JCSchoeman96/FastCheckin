# Queue And Flush

## Runtime Truth

- Raw scanned payload must currently be preserved exactly; no client normalization policy is promoted.
- Active Android UI and use cases currently enqueue only `IN`.
- Android runtime remains effectively IN-only; OUT is not a promoted successful business flow.
- If future or accidental code inserts `OUT`, the queued direction is preserved
  through storage and upload so the backend rejects it honestly instead of the
  client silently rewriting it to `IN`.
- redis_authoritative is the target/proven path in tests and perf; legacy and shadow are fallback/migration modes; deployed production truth cannot be proven from repo code alone.

## Queue Shape

Queued scans are modeled for one upload shape only:

```json
{ "scans": [ ... ] }
```

There is no runtime support for `{ "batches": ... }`.

## Queue Rules

- every captured scan is written locally first
- queue entries are keyed by `idempotency_key`
- Room enforces unique `idempotency_key` at the local queue layer
- replay suppression is a local-only 3 second UX guard keyed by the exact raw
  `ticket_code` value currently queued for upload
- replay suppression is true only when `injected_now - seenAtEpochMillis <
  3_000`
- expired replay-suppression rows are treated as expired immediately and are
  replaced inline on the next queue attempt for that exact `ticket_code`
- replay cache stores server-terminal results by `idempotency_key`
- `createdAt` is stored as UTC epoch millis (`Long`) and is the only queue
  ordering field
- `scannedAt` remains backend payload data and does not control queue order

## Flush Rules

- foreground/manual flush orchestration is owned by
  `core.autoflush.DefaultAutoFlushCoordinator` (single in-flight, in-process)
- WorkManager flush remains available for background execution via
  `worker/FlushQueueWorker` when or if app code enqueues it
- coordinator max batch size is currently `25` per flush run
- repository/use case default max batch size remains `50` when invoked directly
- the worker reconciles results by `idempotency_key`
- returned terminal items are replay-cached and removed from the queue
- missing result items are kept for retry
- HTTP `401` stops flushing and preserves queue state
- `FlushReport` is the active queue/flush result contract; the old aggregate
  `FlushSummary` contract is no longer used

## Partial Success

Transport success does not guarantee that every queued item completed. The flush
algorithm therefore treats returned items and missing items separately.

## No Local Business Approval

The queue layer does not implement strong local check-in approval logic. It
captures, suppresses obvious replay, and uploads. The server decides business
outcomes.

Android must classify queue completion from `status` and missing rows, not from
parsing backend `message` strings into business truth.

## UI Truth Vocabulary

Operators must be able to distinguish:

- queued locally: items are persisted in `queued_scans` and await upload
- upload state: transient orchestration state such as Uploading, Retry pending,
  Auth expired, or Idle
- server result: only shown after the backend has classified persisted flush
  outcomes

Do not infer "invalid / not found" from message strings. Terminal errors remain
generic rejected-by-server outcomes unless the backend later promotes stable
structured result codes.
