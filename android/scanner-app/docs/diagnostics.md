# Diagnostics

Current diagnostics should focus on runtime realities of the current Phoenix
mobile contract.

## Truth model (post-B1)

Diagnostics distinguishes three categories explicitly:

- **Queued locally**: durable local queue depth from Room/repository observation.
- **Upload state**: transient coordinator state (Uploading / Retry pending / Auth expired / Idle).
- **Server result**: summary derived only from persisted/classified flush outcomes.

Ownership:

- **Repository/Room** = durable truth (queue depth, persisted latest flush snapshot + outcomes).
- **AutoFlushCoordinator** = transient runtime truth (in-flight upload, retry scheduled metadata).
- **ViewModel/factory** = projection only (no manual “refresh UI after X” for durable data).

## B3 assumptions (recorded technical debt)

- **Latest sync ordering assumption**: Diagnostics derives “latest sync” from `sync_metadata.lastSuccessfulSyncAt` (currently backend/server time) as a proxy for the most recent successful *local* sync. If that proves unstable (out-of-order server_time), introduce a local completion timestamp and order by that instead.
- **Atomicity assumption**: attendee upsert and sync metadata upsert are sequential, not a single Room transaction. If partial-sync edge cases appear, collapse them into one DAO `@Transaction` write.

## Core Signals

- current event/session metadata
- JWT auth-present vs auth-expired state
- attendee sync recency
- queued locally depth (Room-backed)
- replay cache behavior
- upload state (coordinator transient state)
- server result summary (persisted outcomes)
- connectivity state
- thermal state placeholder
- app version

## Scope Limit

Diagnostics must not assume future backend device-session or package-health
surfaces yet. If those routes exist on the server, they are future-facing only
for Android runtime.
