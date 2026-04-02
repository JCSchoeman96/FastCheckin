# Runtime Data Capability Audit

## Purpose

This document audits what the future `Scan`, `Search`, and `Event` destinations
can support using the current Android runtime contract and current local data
model. It is intended to stop future implementation from inventing unsupported
behavior.

This is a planning document only.

## Active Runtime Contract

Android runtime remains limited to:

- `POST /api/v1/mobile/login`
- `GET /api/v1/mobile/attendees`
- `POST /api/v1/mobile/scans`

This audit must not assume:

- device-session APIs
- event package/config/health APIs
- a richer scan decision taxonomy than the current upload result model
- any server-pushed real-time event metrics

## Truth Layers

The future runtime needs to reason about 3 Android truth layers separately.

### 1. Room / Local Persistence Truth

`AttendeeEntity` is the current durable attendee truth stored locally.

It already stores more detail than the current domain/UI projection exposes:

- `id`
- `eventId`
- `ticketCode`
- `firstName`
- `lastName`
- `email`
- `ticketType`
- `allowedCheckins`
- `checkinsRemaining`
- `paymentStatus`
- `isCurrentlyInside`
- `updatedAt`

This means some future UI work is not backend-blocked. It is blocked only by
Android-side projection and query work.

### 2. Domain / UI Projection Truth

`AttendeeRecord` is the current trimmed projection exposed upward today:

- `id`
- `eventId`
- `ticketCode`
- `fullName`
- `ticketType`
- `paymentStatus`
- `isCurrentlyInside`
- `updatedAt`

`AttendeeRecord` does not expose:

- `email`
- `allowedCheckins`
- `checkinsRemaining`
- separate `firstName` and `lastName`

It also cannot expose attendee fields that Android does not currently persist,
even though they are present in the sync payload, such as `checked_in_at` and
`checked_out_at`.

### 3. DAO / Query Truth

`ScannerDao` currently provides:

- exact attendee lookup by `eventId` and `ticketCode`
- sync metadata access
- queue depth access
- latest flush snapshot and recent outcomes

`ScannerDao` does not currently provide:

- free-text attendee search
- paged attendee queries for lists
- aggregate attendee projections such as current-inside counts

That means some future product behavior is possible with Android-side DAO work,
but not supported now.

## Capability Matrix

| Surface / feature | Current truth source | Capability status | Notes |
| --- | --- | --- | --- |
| Login and session summary | `SessionRepository`, session metadata, token presence | Supported now | Current runtime already logs in and projects active event/session state. |
| Scan queueing and upload status | `QueueCapturedScanUseCase`, `MobileScanRepository`, `AutoFlushCoordinator`, Room queue depth | Supported now | Current runtime already queues locally, auto-flushes, and surfaces upload state. |
| Scanner capture feedback | `ScanCapturePipeline`, `ScanningViewModel`, persisted flush outcomes | Supported now | Must stay honest: queued locally is not server-confirmed admission. |
| Exact attendee lookup by ticket code | `ScannerDao.findAttendee(eventId, ticketCode)` | Supported with Android-side use-case/UI work | DAO exact lookup exists, but there is no Search destination or dedicated use case yet. |
| Free-text attendee search by name/email | `AttendeeEntity` fields are present, but no DAO query exists | Supported with Android-side DAO/projection/model work | Requires DAO queries, indexing/perf review, and Search UI work. Not blocked on backend expansion. |
| Attendee detail card | `AttendeeEntity` contains more detail than `AttendeeRecord` | Supported with Android-side model/projection work | Existing domain projection drops useful fields; Search/detail UI needs a richer projection. |
| Checked-in / checked-out timestamps in attendee detail | Present in sync payload, not persisted in `AttendeeEntity` | Supported with Android-side persistence/model work | Requires Android entity/mapper/model expansion, not backend expansion. |
| Manual check-in from Search | Existing local queue-and-flush `IN` path | Supported with Android-side use-case/UI work | Must reuse the current local queue path. It is not a separate admission API and must not imply immediate success. |
| Manual checkout from Search | Current mobile runtime remains effectively `IN`-only | Blocked until backend contract/runtime expansion | `OUT` is not a promoted successful business flow today. |
| Event total attendees | `SyncMetadataEntity.attendeeCount` | Supported now | Current sync metadata already tracks total attendees for the last successful sync. |
| Event sync freshness | sync metadata plus coordinator state | Supported now | Can already surface last sync time and upload state honestly. |
| Event queue depth | Room queue depth | Supported now | Already available from repository/DAO observation. |
| Event last flush summary | latest flush snapshot plus recent outcomes | Supported now | Already available from persisted flush state. |
| Event current-inside count | `AttendeeEntity.isCurrentlyInside` | Supported with Android-side aggregation work | Derivable locally, but only as sync-stale local projection, not server-live truth. |
| Event remaining-checkins summary | `allowedCheckins` and `checkinsRemaining` exist in `AttendeeEntity` | Supported with Android-side aggregation/model work | Also sync-stale local projection. Not exposed through current domain/UI projection. |
| Event authoritative real-time occupancy / event health | no active backend route | Blocked until backend contract expansion | Requires promoted server-side event health/metrics APIs. |
| Rich server decision explanations in UI | current scan result model is broad `status` plus optional `reason_code` | Blocked until backend contract expansion | Android must not invent a richer decision taxonomy than the backend provides. |

## Search Screen Conclusions

The future `Search` destination can be honest and useful, but only if it
separates current support from required Android-side work.

### Supported Now

Nothing user-facing is fully supported now because there is no Search surface,
no DAO search query set, and no Search view model.

### Supported With Android-Side Work

The following are not backend-blocked:

- exact ticket-code lookup
- free-text search by attendee name or email
- attendee detail surfaces that expose fields already stored in
  `AttendeeEntity`
- richer attendee detail surfaces that persist and project currently dropped
  sync payload fields
- manual check-in that enqueues an `IN` scan through the existing queue path

### Blocked

The following are blocked until future backend/runtime promotion:

- authoritative manual checkout flow
- richer server-approved decision states beyond current upload result truth
- real-time event health that Search could treat as live backend authority

## Event Screen Conclusions

The future `Event` destination can be more useful than the current diagnostics
panel without pretending to be a backend admin console.

### Supported Now

- current event/session summary
- attendee count from last successful sync
- sync freshness
- queue depth
- upload state
- persisted last flush summary and recent server-result summary

### Supported With Android-Side Aggregation / Projection Work

- local current-inside counts
- local remaining-checkins summaries
- local ticket-type or payment-status summaries

These are valid only as sync-stale local projection truth. They must not be
described as authoritative real-time server state.

### Blocked

- server-live event health
- promoted occupancy/operations APIs
- gate/device metrics
- machine-readable decision detail beyond the existing upload result model

## Attendee Model Gap Summary

The current gap is not only "backend missing fields." It is also "Android drops
or does not persist fields it could use later."

There are 3 classes of gaps:

### Already Stored Locally But Not Exposed Cleanly

- `email`
- `allowedCheckins`
- `checkinsRemaining`
- separate `firstName` and `lastName`

These are Android-side projection gaps.

### Present In Sync Payload But Not Persisted Locally

- `checked_in_at`
- `checked_out_at`

These require Android-side persistence/model work, not backend expansion.

### Not Available Through The Current Contract

- real-time event health
- authoritative live event summaries
- richer scan decision taxonomy

These require future backend contract expansion.

## Guardrails For Later Implementation

Future Search/Event implementation must preserve these rules:

- local queue acceptance is not server-confirmed admission
- local attendee data is a mirror and may be stale
- local aggregations are projection truth, not backend authority
- no Search/Event design should assume routes beyond `/api/v1/mobile/*`
- no manual check-in flow should bypass the existing queue-and-flush path

## Handoff

This audit supports the locked implementation order:

1. Phase 9: login/bootstrap plus authenticated shell scaffold
2. Phase 10: smartphone-first `Scan` runtime
3. Phase 11: Search DAO/projection/model work plus Search UI
4. Phase 12: Event operational surface
