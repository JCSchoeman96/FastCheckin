# Local Persistence

## Room

Room is the structured local runtime store for:

- attendee cache
- queued scans
- local admission overlays
- quarantined scans
- replay cache
- local replay suppression
- latest flush snapshot
- recent flush outcomes
- sync metadata

Tables:

- `attendees`
- `queued_scans`
- `local_admission_overlays`
- `quarantined_scans`
- `local_replay_suppression`
- `scan_replay_cache`
- `latest_flush_snapshot`
- `recent_flush_outcomes`
- `sync_metadata`

Rules:

- DTOs are never stored directly without mapping
- domain models are never reused as Room entities
- queued scans are idempotency-first
- queued scans are durable local operational truth
- local admission overlays are durable unresolved-state truth
- quarantined scans are durable runtime/audit truth and preserved by default
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
