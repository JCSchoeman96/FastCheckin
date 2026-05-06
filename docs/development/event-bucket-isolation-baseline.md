# Event Bucket Isolation Baseline (Phase 0)

## Scope

This note captures the current implementation baseline before Phase 1 changes. It focuses on Android event switching/local state and Phoenix mobile sync/upload boundaries only.

## Current Android behavior baseline

### Login blocking and unresolved-state gate

- `CurrentPhoenixSessionRepository.login(...)` calls `unresolvedAdmissionStateGate.requireNoConflictingEvents(eventId)` **before** remote login, so unresolved local state in other events blocks switching. 
- `UnresolvedAdmissionStateGate` reads unresolved event IDs via `ScannerDao.loadUnresolvedEventIdsExcluding(targetEventId)` and throws `CrossEventUnresolvedStateException` if any are found.

Implication: unresolved event 1 local state can block login to event 10.

### What counts as unresolved local state

From `ScannerDao` unresolved queries:

- `queued_scans` rows where `replayed = 0`
- `local_admission_overlays` rows in active/conflict states:
  - `PENDING_LOCAL`
  - `CONFIRMED_LOCAL_UNSYNCED`
  - `CONFLICT_DUPLICATE`
  - `CONFLICT_REJECTED`

### Runtime cleanup behavior on transitions/logout/auth-expiry

- `DefaultLocalRuntimeDataCleaner` uses `RuntimeDataRetentionPolicy`.
- `handleCleanEventTransition(fromEventId, toEventId)` clears **from-event** attendees/sync metadata, and globally clears replay suppression, replay cache, latest flush snapshot, and recent flush outcomes.
- `handleExplicitLogout` and `handleAuthExpired` apply policy-based table clears.
- Policy explicitly preserves queued scans, local admission overlays, and quarantined scans (`preserve* = true`).

Risk: replay suppression is globally cleared/scoped today, not event-bucket scoped.

## Room table scoping baseline

### Event-scoped tables/records

- `queued_scans` (`QueuedScanEntity`) has `eventId`.
- `local_admission_overlays` (`LocalAdmissionOverlayEntity`) has `eventId` and event-based indexes.
- `quarantined_scans` (`QuarantinedScanEntity`) has `eventId` and event/time indexes.
- `attendees` and `sync_metadata` are managed with per-event delete/query methods in `ScannerDao`.

### Global/non-event-scoped risk table

- `local_replay_suppression` (`LocalReplaySuppressionEntity`) is keyed uniquely by `ticketCode` only (no `eventId`).
- `ScannerDao.findReplaySuppression(ticketCode)` is also global by ticket code.
- `latest_flush_snapshot` and `recent_flush_outcomes` are global status surfaces today (not event-scoped), so they can show stale/misleading flush status after event switching unless made bucket-aware later.

Risk: same ticket code across events can leak suppression behavior cross-event.

## Database and migrations baseline

- `FastCheckDatabase` currently includes scanner runtime tables (attendees, queue, replay cache, sync metadata, replay suppression, overlays, flush snapshot, flush outcomes, quarantine).
- DB version is currently `10`.
- `FastCheckDatabaseMigrations` already includes prior rebuild/normalization and overlay/sync metadata related migrations; no event-bucket lifecycle table exists yet.

## Backend mobile route/sync baseline

### Router/auth boundaries

From `lib/fastcheck_web/router.ex`:

- Public mobile login: `POST /api/v1/mobile/login` under `:api`.
- Authenticated mobile sync/upload routes under `:mobile_api` (includes `FastCheckWeb.Plugs.MobileAuth`):
  - `GET /api/v1/mobile/attendees`
  - `POST /api/v1/mobile/scans`

### Sync-down behavior

From `Mobile.SyncController.get_attendees`:

- Event is taken from `conn.assigns.current_event_id` (JWT-authenticated context).
- Supports incremental/full sync semantics with paging (`limit`, optional `cursor`) and invalidation checkpointing (`since_invalidation_id`).

### Sync-up behavior

From `Mobile.SyncController.upload_scans` + `FastCheck.Scans.MobileUploadService`:

- Batch uploads are validated and processed via authoritative hot-state service.
- Durability handoff is queued via Oban (`PersistScanBatchJob`).
- Per-item API results include success/duplicate/error handling.

## Phase risks to address next (without implementing now)

1. **Event switch hard-block**: cross-event unresolved state currently prevents login progression.
2. **Cross-event suppression leak**: replay suppression is global by ticket code.
3. **No explicit event-bucket lifecycle**: unresolved/syncing/closing states are inferred, not tracked as first-class per-event bucket records.
4. **Global cleanup surfaces**: some runtime cleanup actions are global, not explicitly per-event bucket.

## Intended phase sequence (implementation)

1. Replace hard unresolved-state login block with non-blocking event switch policy.
2. Add explicit event-bucket lifecycle entity/state.
3. Make replay suppression event-scoped (`eventId + ticketCode`).
4. Add background bucket flush/retry workers.
5. Add safe auto-close for resolved buckets.
6. Add diagnostics-only force archive preserving evidence.
7. Add server-side mobile scanner issue ingest.
8. Add admin issue review surfaces.
9. Tune sync frequency with debounced triggers/backoff.
