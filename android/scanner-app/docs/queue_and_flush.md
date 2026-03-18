# Queue And Flush

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
- replay suppression is a local-only 3 second UX guard keyed by raw
  transported `ticket_code`
- replay suppression is true only when `injected_now - seenAtEpochMillis <
  3_000`
- expired replay-suppression rows are treated as expired immediately and are
  replaced inline on the next queue attempt for that `ticket_code`
- replay cache stores server-terminal results by `idempotency_key`
- runtime direction exposure is `IN` only
- the temporary manual/debug queue screen lives in `feature.queue`, not in
  `feature.scanning`
- `createdAt` is stored as UTC epoch millis (`Long`) and is the only queue
  ordering field
- `scannedAt` remains backend payload data and does not control queue order

## Flush Rules

- Foreground/manual flush orchestration is owned by `core.autoflush.DefaultAutoFlushCoordinator` (single in-flight, in-process).
- WorkManager flush remains available for background execution via `worker/FlushQueueWorker` when/if it is enqueued by app code.
- Coordinator max batch size is currently `25` per flush run (bounded drain loop may run multiple times).
- Repository/use case default max batch size remains `50` when invoked directly.
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

## UI truth vocabulary (post-B1)

Operators must be able to distinguish:

- **Queued locally**: item(s) are persisted in `queued_scans` and await upload.
- **Upload state**: transient orchestration state (Uploading / Retry pending / Auth expired / Idle).
- **Server result**: only shown after the backend has classified persisted flush outcomes.

Do not infer “invalid / not found” from message strings. Terminal errors remain the generic “Rejected by server” unless/until the backend provides stable structured outcome codes.
