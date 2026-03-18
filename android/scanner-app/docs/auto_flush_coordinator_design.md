# AutoFlushCoordinator boundary — design note

**Purpose:** Define the narrowest Android layer that owns automatic flush orchestration and a single coordinator boundary. No backend contract changes. Local queue remains the durable offline-first source of truth. Real-time validation and flush execution stay in-process (no move to WorkManager in this slice). One device never runs more than one in-flight flush at a time.

---

## 1) Owner for auto-flush state and orchestration

**Single owner:** `AutoFlushCoordinator`

- **Role:** Orchestrates all flush execution (manual and auto). Owns online detection, in-flight exclusivity, batch trigger rules, and optional retry/backoff.
- **Scope:** Process singleton. One instance per app process → one in-flight flush per device.
- **Does not own:** Queue admission, persistence, or API contracts. It only decides *when* to run flush and *that* at most one run is active; it delegates the actual flush to `FlushQueuedScansUseCase`.

---

## 2) Files to add or change

### Add (new)

| File | Purpose |
|------|--------|
| `core/autoflush/AutoFlushCoordinator.kt` | Coordinator class: holds flush mutex, applies trigger rules, calls `FlushQueuedScansUseCase`, exposes `StateFlow<AutoFlushCoordinatorState>`. |
| `core/autoflush/AutoFlushCoordinatorState.kt` | State data class: `isFlushing: Boolean`, `lastFlushReport: FlushReport?`, optional `lastTrigger: Trigger?`. |
| `core/autoflush/AutoFlushTrigger.kt` | Sealed type: `Manual`, `AfterEnqueue` (and later e.g. `ConnectivityRestored`, `BackoffElapsed`). |
| `core/autoflush/ConnectivityProvider.kt` | Interface: `suspend fun isOnline(): Boolean` (or `Flow<Boolean>`). Implementation can be stub (“always true”) or use `ConnectivityManager`; keeps coordinator testable and online-detection in one place. |

### Change (existing)

| File | Change |
|------|--------|
| `app/di/RepositoryModule.kt` (or new `app/di/AutoFlushModule.kt`) | Provide/bind `AutoFlushCoordinator` (singleton) and `ConnectivityProvider`. Ensure the coordinator can call `FlushQueuedScansUseCase` and query `pendingQueueDepth()` via `MobileScanRepository` or a narrow abstraction. |
| `app/MainActivity.kt` | Inject `AutoFlushCoordinator`. In the existing `handoffResults.collectLatest { ... }` collector, when `result is CaptureHandoffResult.Accepted`, call `autoFlushCoordinator.requestFlush(AutoFlushTrigger.AfterEnqueue)` (non-blocking). |
| `feature/queue/QueueViewModel.kt` | Inject `AutoFlushCoordinator`. For the manual flush button, replace direct `flushQueuedScansUseCase.run()` with `autoFlushCoordinator.requestFlush(AutoFlushTrigger.Manual)` and observe `coordinator.state` to drive `isFlushing` and the last flush message. After manual enqueue, when `result is QueueCreationResult.Enqueued`, call `autoFlushCoordinator.requestFlush(AutoFlushTrigger.AfterEnqueue)`. |

### Do not change (in this slice)

- **ScanCapturePipeline:** No coordinator dependency; it stays focused on decode gating, queue admission, and local capture outcomes only.
- **SyncViewModel / DiagnosticsViewModel:** No change. Diagnostics keep reading queue depth and latest flush from repositories (`MobileScanRepository.pendingQueueDepth()`, `latestFlushReport()`); coordinator does not replace those sources of truth.
- **Repositories / use cases:** No API or contract changes. `FlushQueuedScansUseCase`, `MobileScanRepository`, backend contracts unchanged. Local queue remains written only via `queueScan()` and read via existing DAO.

---

## 3) State machine and events

### States (coordinator internal)

| State | Meaning |
|-------|--------|
| **Idle** | No flush in progress. `state.isFlushing == false`. |
| **Flushing** | One flush run is in progress. `state.isFlushing == true`. |

Additional internal flag: `flushRequestedWhileBusy: Boolean` (initially `false`). No explicit “Scheduled” or “Cooldown” state is introduced in this slice.

### Events (input to coordinator)

| Event | Source | Coordinator reaction |
|-------|--------|----------------------|
| **RequestFlush(Manual)** | QueueViewModel (button) | If Idle: transition to Flushing and start a flush run. If Flushing: do not start a second run; set `flushRequestedWhileBusy = true`. |
| **RequestFlush(AfterEnqueue)** | MainActivity (after `CaptureHandoffResult.Accepted`) or QueueViewModel (after `QueueCreationResult.Enqueued`) | If Idle and (optional) online and (optional) debounce rules pass: transition to Flushing and start a flush run. If Flushing or rules fail: do not start a second run; set `flushRequestedWhileBusy = true`. |

On flush completion:

- After `FlushQueuedScansUseCase.run()` returns a `FlushReport`, the coordinator:
  - Updates `state.lastFlushReport` and sets `state.isFlushing = false`.
  - Derives whether the run made progress (for example, from a processed or uploaded count on the report).
  - Optionally consults `pendingQueueDepth()` **only** when the run made progress.
  - If `flushRequestedWhileBusy == true`, it clears `flushRequestedWhileBusy = false` and immediately starts one more bounded flush.
  - Else if the previous run made progress **and** the queue still has pending items, it immediately starts one more bounded flush.
  - Otherwise, it remains in Idle with `flushRequestedWhileBusy = false`.

### Invariants

- At most one flush run at a time: only the coordinator calls `FlushQueuedScansUseCase.run()`; coordinator never starts a second run while `isFlushing == true`.
- Flush requests received while a run is in progress are not dropped; they set `flushRequestedWhileBusy` and will cause a follow-up flush after the current run if the queue is still non-empty.
- Flush outcome is persisted by the existing repository (`replaceLatestFlushState`); coordinator only stores `lastFlushReport` in memory for UI (e.g. QueueViewModel “last action”); diagnostics continue to read from repository.

---

## 4) Coordinator API (proposed)

```kotlin
// AutoFlushCoordinator.kt (conceptual)
interface AutoFlushCoordinator {
    val state: StateFlow<AutoFlushCoordinatorState>
    fun requestFlush(trigger: AutoFlushTrigger)
}

// AutoFlushCoordinatorState.kt
data class AutoFlushCoordinatorState(
    val isFlushing: Boolean = false,
    val lastFlushReport: FlushReport? = null
)

// AutoFlushTrigger.kt
sealed interface AutoFlushTrigger {
    data object Manual : AutoFlushTrigger
    data object AfterEnqueue : AutoFlushTrigger
}
```

- **requestFlush(trigger):** Non-blocking. If Idle and (for AfterEnqueue) rules allow, launches a coroutine that sets isFlushing, runs `FlushQueuedScansUseCase.run(maxBatchSize = 50)`, updates state with report and isFlushing = false. Uses a single mutex or single coroutine/job so overlapping calls do not start a second run.
- **Online detection:** Inside the coordinator, before starting flush for `AfterEnqueue`, call `connectivityProvider.isOnline()`; if false, skip starting flush (queue remains durable; flush later on Manual or when online). For `Manual`, optional: skip if offline to avoid pointless failure, or allow attempt (current repository already handles network failure and RETRYABLE).
- **Batch trigger rules (minimal slice):** “AfterEnqueue” → if Idle and online, start one flush. Optional: debounce (e.g. ignore AfterEnqueue if last flush completed &lt; N seconds ago) to be added in coordinator only.

---

## 5) Data flow summary

- **Queue admission:** Unchanged. ScanCapturePipeline / QueueViewModel → `QueueCapturedScanUseCase` → `MobileScanRepository.queueScan()` → DAO. Local queue is still the only durable source of truth for pending scans.
- **Flush execution:** QueueViewModel (button) and MainActivity / QueueViewModel (after successful enqueue) call `AutoFlushCoordinator.requestFlush(…)`. The coordinator runs `FlushQueuedScansUseCase.run()` (single in-flight, with the pending-work flag logic) and repositories/DAO update as today; coordinator updates `lastFlushReport` in state.
- **UI:** QueueViewModel collects `coordinator.state` → derives `isFlushing` and the latest flush message for the flush button and status text. DiagnosticsViewModel is unchanged; it still uses `refresh()` and repositories for queue depth and latest flush.

---

## 6) Risks and boundaries

- **No smear:** Flush logic lives only in AutoFlushCoordinator and the single call site to `FlushQueuedScansUseCase`. MainActivity, SyncViewModel, DiagnosticsViewModel stay free of flush orchestration.
- **One in-flight flush:** Enforced inside coordinator by not starting a new run while `isFlushing` is true.
- **Offline-first:** Queue admission and persistence unchanged. Coordinator only decides when to *attempt* flush; repository already handles network errors and retryable state.
- **Real-time path:** Flush runs in-process (coroutine), not in WorkManager, so no move to background-only in this slice.

---

*Design note only; implementation to follow in a separate slice.*
