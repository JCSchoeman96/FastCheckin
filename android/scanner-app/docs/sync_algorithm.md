# Sync Algorithm

## Attendee Sync Source

Attendees are synced only through:

- `GET /api/v1/mobile/attendees`

## Flow

1. Read current session metadata to obtain active `event_id`.
2. Read existing `sync_metadata` for the last known server timestamp, `lastInvalidationsCheckpoint`, and (optional) `lastEventSyncVersion`.
3. Page `GET /api/v1/mobile/attendees` with `limit`, optional `since`, optional `cursor` (attendees only), and `since_invalidation_id` from the last `invalidations_checkpoint` (default `0` after a full local reconcile).
4. For each response: **apply `invalidations` first** (remove local attendee rows by canonical `ticket_code`), then upsert `attendees`. Invariant is covered by `CurrentPhoenixSyncRepositoryTest.syncAppliesInvalidationsBeforeAttendeeUpsertsForSameTicketCode`.
5. Repeat HTTP calls until **both** the attendee cursor is exhausted (`next_cursor` absent for the current `since` scope) **and** the invalidation stream has no backlog at the response cap (if the server returns `limit` invalidation rows, request again with the updated `since_invalidation_id` while holding the same attendee `cursor` if needed — see `docs/mobile_runtime_truth.md`).
6. Update `sync_metadata` with `server_time`, sync type, attendee count, `lastInvalidationsCheckpoint`, and `lastEventSyncVersion`.

## Rules

- The server is the business-rule authority.
- Local attendee data is a cache, not approval logic.
- Invalid or unsupported `since` handling is owned by the backend.
- The client must not infer gate/device/package state from sync payloads.
- Do **not** infer ticket revocation from “missing row” on incremental attendee pages; use **`invalidations`** explicitly.

## Failure Handling

- network and transport failures are retryable
- auth failure stops sync until manual login
- sync metadata is updated only after successful attendee persistence
