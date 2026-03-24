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
- replay suppression is a local-only 3 second UX guard keyed by raw transported
  `ticket_code`
- replay cache stores server-terminal results by `idempotency_key`
- runtime direction exposure is `IN` only
- the temporary manual/debug queue screen lives in `feature.queue`, not in
  `feature.scanning`
- `createdAt` is stored as UTC epoch millis and is the queue ordering field
- `scannedAt` remains backend payload data and does not control queue order

## Flush Rules

- Foreground/manual flush orchestration is owned by
  `core.autoflush.DefaultAutoFlushCoordinator`.
- Auto-flush is the normal path after queue admission, connectivity restore,
  foreground resume, login, and sync triggers.
- WorkManager flush remains available for background execution via
  `worker/FlushQueueWorker` when/if it is enqueued by app code.
- Manual flush remains fallback/debug control; it is not the only intended
  runtime path.
- Coordinator max batch size is currently `25` per flush run.
- Repository/use case default max batch size remains `50` when invoked
  directly.
- the worker reconciles results by `idempotency_key`
- returned terminal items are replay-cached and removed from the queue
- missing result items are kept for retry
- HTTP `401` stops flushing and preserves queue state
- `FlushReport` is the active queue/flush result contract

## Backend Runtime Truth

For the promoted mobile path, the backend sequence is:

`validate -> hot-state decision -> enqueue durability -> promote results -> respond`

Operationally:

- admission and idempotency are decided synchronously by backend hot state
- acknowledgement happens only after durability jobs are enqueued
- durable Postgres projection is async and happens after acknowledgement
- local queue acceptance must never be presented as server-confirmed admission

## Partial Success

Transport success does not guarantee that every queued item completed. The flush
algorithm treats returned items and missing items separately.

## No Local Business Approval

The queue layer does not implement strong local check-in approval logic. It
captures, suppresses obvious replay, and uploads. The server decides business
outcomes.

## UI Truth Vocabulary

Operators must be able to distinguish:

- **Queued locally**: item(s) are persisted in `queued_scans` and await upload.
- **Upload state**: transient orchestration state (Uploading / Retry pending /
  Auth expired / Idle).
- **Server result**: only shown after the backend has classified persisted
  flush outcomes.

Do not infer invalid/not found from message strings. Android continues to key
runtime behavior off `status`; any backend `reason_code` remains additive unless
the contract is versioned.

Proven `reason_code` refinements remain only:

- `replay_duplicate`
- `business_duplicate`
- `payment_invalid`

`replay_duplicate` is trustworthy only for final replay duplicates. If the
backend has not emitted that final reason, concurrent same-idempotency
ambiguity must remain broad. Missing result rows after HTTP 200 remain
retryable.

Diagnostics remain the canonical detailed server-truth surface. The queue panel
may show one concise persisted server-result hint, but that hint must be
derived from persisted latest flush truth, not from local queue contents or
coordinator-only in-memory state.
