# Auto-flush architecture audit

**Purpose:** Define the narrowest safe auto-flush architecture without changing code yet.  
**Status:** Audit only; no implementation.

---

## 1) Current local queue admission path

| Step | Owner | What happens |
|------|--------|----------------|
| 1 | **Camera/ML Kit** | Decodes barcode → emits to `ScannerInputSource.captures`. |
| 2 | **ScannerSourceBinding** | Collects `source.captures`, calls `decodedBarcodeHandler.onDecoded(rawValue)`. |
| 3 | **ScanCapturePipeline** | Implements `DecodedBarcodeHandler`. Applies 1s cooldown; then calls `QueueCapturedScanUseCase.enqueue(ticketCode, direction, operatorName, entranceName)`. Emits `CaptureHandoffResult` (Accepted / SuppressedByCooldown / Failed) to `handoffResults`. |
| 4 | **DefaultQueueCapturedScanUseCase** | Validates ticket code; gets `eventId`/operator from `SessionAuthGateway`; builds `PendingScan` with new UUID idempotency key; calls `MobileScanRepository.queueScan(scan)`. |
| 5 | **CurrentPhoenixMobileScanRepository** | Replay suppression (3s window via `ScannerDao` replay_suppression table); `scannerDao.insertQueuedScan(scan.toEntity())`; returns `Enqueued` or `ReplaySuppressed`. |

**Manual queue admission:** `MainActivity` → `QueueViewModel.queueManualScan()` → same `QueueCapturedScanUseCase.enqueue()` with manual ticket code and "Manual Debug" operator/entrance.

**Truth for “item just queued”:** The only write to the queue is `ScannerDao.insertQueuedScan()`. Queue depth is not stored in a ViewModel; it is read on demand.

---

## 2) Current flush/upload path

| Step | Owner | What happens |
|------|--------|----------------|
| 1 | **User** | Taps "Flush queue" → `MainActivity` calls `queueViewModel.flushQueuedScans()`. |
| 2 | **QueueViewModel** | Sets `isFlushing = true`; calls `FlushQueuedScansUseCase.run(maxBatchSize = 50)`; updates UI with `actionMessageForFlushReport(report)` and optional validation message (e.g. auth expired). |
| 3 | **DefaultFlushQueuedScansUseCase** | Delegates to `MobileScanRepository.flushQueuedScans(maxBatchSize)`. |
| 4 | **CurrentPhoenixMobileScanRepository** | Loads batch via `scannerDao.loadQueuedScans(maxBatchSize)`; if no token → persists and returns AUTH_EXPIRED report; if empty → returns COMPLETED report; else calls `remoteDataSource.uploadScans(queued.map { it.toPayload() })`; classifies results; writes terminal outcomes to replay cache; deletes successfully processed rows from `queued_scans`; persists latest flush snapshot + recent outcomes via `replaceLatestFlushState()`; returns `FlushReport`. |

**Flush is fully manual today:** The only trigger is the "Flush queue" button. There is no automatic flush on a timer, on connectivity change, or after N enqueues.

**FlushQueueWorker** exists and uses `FlushQueuedScansUseCase`, but it is **never enqueued** anywhere (no `WorkManager.enqueue(OneTimeWorkRequest)` or similar). So background flush is scaffold only.

**Truth for “last flush”:** `CurrentPhoenixMobileScanRepository.persistLatestFlushReport()` → `ScannerDao.replaceLatestFlushState(snapshot, outcomes)`. Read via `latestFlushReport()` → `loadLatestFlushSnapshot()` + `loadRecentFlushOutcomes()`.

---

## 3) Current diagnostics state sources

| Diagnostic | Source (single source of truth) |
|------------|----------------------------------|
| **Queue depth** | `MobileScanRepository.pendingQueueDepth()` → `ScannerDao.countPendingScans()` (count of `queued_scans` where `replayed = 0`). |
| **Recent outcomes** | `MobileScanRepository.latestFlushReport()` → `ScannerDao.loadLatestFlushSnapshot()` + `loadRecentFlushOutcomes(5)`; `DiagnosticsUiStateFactory` takes first 3 `itemOutcomes` and formats as `recentOutcomeSummary`. |
| **Latest flush state / summary** | Same `latestFlushReport()`; `executionStatus` and `summaryMessage` mapped in `DiagnosticsUiStateFactory`. |
| **Attendee count** | `SyncRepository.currentSyncStatus()` → `CurrentPhoenixSyncRepository`: `sessionRepository.currentSession()?.let { scannerDao.loadSyncMetadata(it.eventId) }?.toDomain()`; `AttendeeSyncStatus.attendeeCount` from `SyncMetadataEntity`. |
| **Sync status (last sync time, sync type)** | Same `currentSyncStatus()`; `lastSuccessfulSyncAt`, `syncType` from sync metadata. |
| **Auth/session** | `SessionRepository.currentSession()`, `SessionProvider.bearerToken()`; token expiry derived from session in factory. |

**Refresh trigger:** Pull-only. `DiagnosticsViewModel.refresh()` is called from:
- "Refresh diagnostics" button.
- After auth UI state update (session summary).
- After sync UI state update when not syncing.
- After queue UI state update (so after manual flush or manual queue action).
- Once on launch after permission refresh.

There is no reactive stream from repositories to diagnostics; every value is fetched inside `refresh()`.

---

## 4) Current sync trigger path

**Sync is fully manual.**  
Trigger: "Sync" button → `SyncViewModel.syncAttendees()` → `SyncRepository.syncAttendees()`.

- **CurrentPhoenixSyncRepository.syncAttendees():** Gets current session; loads existing `sync_metadata` for `eventId`; calls `remoteDataSource.syncAttendees(existing?.lastServerTime)`; upserts attendees and sync metadata via `ScannerDao`. Returns `AttendeeSyncStatus` (from metadata).

No automatic sync on app start, timer, or connectivity.

---

## 5) Proposed auto-flush insertion point

- **Narrowest insertion point:** Immediately after a scan is **successfully enqueued** and without changing the existing manual flush path.
- **Concrete options:**
  - **Option A (in-process):** After `ScanCapturePipeline.onDecoded()` gets `QueueCreationResult.Enqueued` (or after `CurrentPhoenixMobileScanRepository.queueScan()` returns `Enqueued`), trigger a **single** best-effort flush (e.g. call `FlushQueuedScansUseCase.run(maxBatchSize)` on a coroutine, no blocking of the pipeline). Keep manual "Flush queue" as-is.
  - **Option B (WorkManager):** When a scan is enqueued (same success point), enqueue a **one-time** `FlushQueueWorker` (replace or defer existing work by tag so only one runs). Worker already uses `FlushQueuedScansUseCase`; no new flush logic.
- **Recommendation:** Prefer **Option A** for the narrowest change: one place (e.g. `ScanCapturePipeline` or a small coordinator that observes enqueue success) calls flush once per enqueue success. Option B is better if the goal is to move all flush off the main process (e.g. to survive process death after enqueue).

**What must not change:** Queue admission path (replay suppression, idempotency, single write to `ScannerDao.insertQueuedScan`). Flush semantics (batch size, AUTH_EXPIRED / RETRYABLE / terminal handling, persistence of `latestFlushReport`). Backend contract and repository API.

---

## 6) Proposed state machine (minimal)

- **Idle:** No flush in progress. Queue may be non-empty.
- **Flushing:** A flush (manual or auto) is running. Optional: debounce further auto-flush until this finishes.
- **Post-flush:** Same as Idle; diagnostics and queue depth reflect latest state.

No need for a formal state machine in code initially; the invariant is: "at most one flush run at a time." If auto-flush is triggered from the same process, either:
- run flush in a dedicated scope and ignore concurrent triggers while `isFlushing`, or
- enqueue WorkManager work and let WorkManager serialize by tag.

---

## 7) Risks and invariants

**Risks:**
- **Connectivity:** App does **not** currently observe connectivity. Auto-flush will attempt network; on failure, `CurrentPhoenixMobileScanRepository` already returns RETRYABLE and persists the report; no change required for correctness. Optional later: only trigger auto-flush when network is available to avoid pointless attempts.
- **Auth expiry:** If token is expired, flush returns AUTH_EXPIRED and persists it; diagnostics already show "Re-login required." Auto-flush does not need to block; manual login remains the fix.
- **Rate / battery:** Triggering flush on every enqueue could cause many small uploads. Mitigation: keep batch size (e.g. 50), and optionally debounce (e.g. one flush per N seconds or one flush per M enqueues).
- **Reordering:** Queue is FIFO (`ORDER BY createdAt ASC, id ASC`). Auto-flush must not change that; it just runs the same `flushQueuedScans(maxBatchSize)`.

**Invariants to preserve:**
- Queue depth truth remains `ScannerDao.countPendingScans()`.
- Recent outcomes and latest flush state truth remain `ScannerDao` (latest flush snapshot + recent outcomes).
- Attendee count and sync status remain `SyncRepository.currentSyncStatus()` / sync metadata.
- Only one writer for queue: `insertQueuedScan`; only one writer for latest flush state: `replaceLatestFlushState`.
- Flush is still the only path that deletes from `queued_scans` and updates replay cache/snapshot.
- Backend remains the authority for check-in acceptance; client only queues and uploads.

---

## File ownership summary

| Concern | Primary files |
|--------|----------------|
| Queue admission (camera path) | `ScanCapturePipeline`, `DefaultQueueCapturedScanUseCase`, `CurrentPhoenixMobileScanRepository`, `ScannerDao` |
| Queue admission (manual) | `QueueViewModel`, `MainActivity` (button) |
| Flush execution | `QueueViewModel` (manual trigger), `FlushQueuedScansUseCase`, `CurrentPhoenixMobileScanRepository`, `FlushQueueWorker` (unused) |
| Queue depth | `ScannerDao.countPendingScans()`, `MobileScanRepository.pendingQueueDepth()`, `DiagnosticsViewModel` (via refresh) |
| Recent outcomes / latest flush | `ScannerDao` (latest_flush_snapshot, recent_flush_outcomes), `CurrentPhoenixMobileScanRepository.latestFlushReport()`, `DiagnosticsUiStateFactory` |
| Attendee count / sync status | `SyncRepository.currentSyncStatus()`, `CurrentPhoenixSyncRepository`, `ScannerDao.loadSyncMetadata()`, `DiagnosticsUiStateFactory` |
| Diagnostics refresh | `DiagnosticsViewModel.refresh()`, `MainActivity` (multiple collectors + button) |
| Sync trigger | `SyncViewModel`, `MainActivity` (sync button) |
| Network/API | `PhoenixMobileRemoteDataSource`, `PhoenixMobileApi`; no connectivity observer |

---

*Audit completed without code changes. Use this document to implement auto-flush in a narrow, safe way.*
