# Sync Algorithm

## Attendee Sync Source

Attendees are synced only through:

- `GET /api/v1/mobile/attendees`

## Flow

1. Read current session metadata to obtain active `event_id`.
2. Read existing `sync_metadata` for the last known server timestamp.
3. Call `/api/v1/mobile/attendees?since=...` when a cursor exists.
4. Map response DTOs into Room attendee entities.
5. Upsert attendees into Room.
6. Update `sync_metadata` with `server_time`, sync type, and attendee count.

## Rules

- The server is the business-rule authority.
- Local attendee data is a cache, not approval logic.
- Invalid or unsupported `since` handling is owned by the backend.
- The client must not infer gate/device/package state from sync payloads.

## Failure Handling

- network and transport failures are retryable
- auth failure stops sync until manual login
- sync metadata is updated only after successful attendee persistence
