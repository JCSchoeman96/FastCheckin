# Diagnostics

Current diagnostics should focus on runtime realities of the current Phoenix
mobile contract.

## Truth Model

Diagnostics distinguishes three categories explicitly:

- **Queued locally**: durable local queue depth from Room/repository
  observation.
- **Upload state**: transient coordinator state (Uploading / Retry pending /
  Auth expired / Idle).
- **Server result**: summary derived only from persisted/classified flush
  outcomes after backend authoritative admission and later durable projection.

Ownership:

- **Repository/Room** = durable truth (queue depth, persisted latest flush
  snapshot + outcomes).
- **AutoFlushCoordinator** = transient runtime truth (in-flight upload, retry
  scheduled metadata).
- **ViewModel/factory** = projection only; no manual refresh of durable truth.

## Current Signals

- current event/session metadata
- JWT auth-present vs auth-expired state
- attendee sync recency
- queued locally depth
- replay cache behavior
- upload state
- server result summary
- connectivity state
- thermal state placeholder
- app version

## Constraints

- diagnostics must not imply that local queue admission equals server acceptance
- diagnostics must not assume future backend device-session or package-health
  surfaces yet
- if those routes exist on the server, they are future-facing only for Android
  runtime
