# Local Persistence

## Room

Room is the structured local runtime store for:

- attendee cache
- queued scans
- replay cache
- sync metadata

Tables:

- `attendees`
- `queued_scans`
- `scan_replay_cache`
- `sync_metadata`

Rules:

- DTOs are never stored directly without mapping
- domain models are never reused as Room entities
- queued scans are idempotency-first
- replay cache records terminal server outcomes by `idempotency_key`

## DataStore

DataStore is for non-secret metadata only:

- current event/session metadata
- operator preference data
- future lightweight non-secret scanner preferences

## Keystore

Keystore-backed storage via `EncryptedSharedPreferences` is used only for JWT
material and other future secrets.

## No Future Runtime Dependencies

No local persistence path should assume device sessions, gates, or offline event
packages as active runtime entities yet.
