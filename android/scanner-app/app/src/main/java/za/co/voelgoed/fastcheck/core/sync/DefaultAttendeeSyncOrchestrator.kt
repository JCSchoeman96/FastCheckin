package za.co.voelgoed.fastcheck.core.sync

import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.ProcessLifecycleOwner
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import java.time.Clock
import java.time.Duration
import java.time.Instant
import kotlin.math.max
import javax.inject.Inject
import javax.inject.Singleton
import kotlin.random.Random
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import za.co.voelgoed.fastcheck.core.connectivity.ConnectivityMonitor
import za.co.voelgoed.fastcheck.data.repository.AttendeeSyncMode
import za.co.voelgoed.fastcheck.data.repository.SessionRepository
import za.co.voelgoed.fastcheck.data.repository.SyncPaginationException
import za.co.voelgoed.fastcheck.data.repository.SyncRepository

/**
 * Event-scoped attendee sync scheduling: coalesced triggers, foreground periodic sync with jitter,
 * and integrity-driven full reconcile mode selection.
 */
@Singleton
class DefaultAttendeeSyncOrchestrator @Inject constructor(
    private val syncRepository: SyncRepository,
    private val sessionRepository: SessionRepository,
    private val connectivityMonitor: ConnectivityMonitor,
    private val clock: Clock
) : AttendeeSyncOrchestrator {
    private val config: AttendeeSyncOrchestratorConfig = AttendeeSyncOrchestratorConfig()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    private val syncRequests = Channel<Unit>(capacity = Channel.CONFLATED)

    @Volatile
    private var sessionIntegrityFailures: Int = 0

    private var consumerJob: Job? = null
    private var periodicJob: Job? = null
    private var connectivityJob: Job? = null
    private var retryJob: Job? = null

    private var lastOnline: Boolean = connectivityMonitor.isOnline.value

    private var started: Boolean = false

    private val lifecycleObserver =
        object : DefaultLifecycleObserver {
            override fun onStart(owner: LifecycleOwner) {
                sessionIntegrityFailures = 0
                notifyAppForeground()
            }
        }

    override fun start() {
        if (started) return
        started = true

        ProcessLifecycleOwner.get().lifecycle.addObserver(lifecycleObserver)

        consumerJob =
            scope.launch {
                for (ignored in syncRequests) {
                    runBackgroundSyncCycle()
                }
            }

        val processOwner = ProcessLifecycleOwner.get()
        periodicJob =
            processOwner.lifecycleScope.launch {
                processOwner.repeatOnLifecycle(Lifecycle.State.STARTED) {
                    while (isActive) {
                        val jitter = Random.nextLong(0, config.periodicJitterMaxMs + 1)
                        delay(config.periodicBaseMs + jitter)
                        enqueueSyncRequest()
                    }
                }
            }

        connectivityJob =
            scope.launch {
                connectivityMonitor.isOnline.collect { online ->
                    if (online && !lastOnline) {
                        notifyConnectivityRestored()
                    }
                    lastOnline = online
                }
            }
    }

    override fun notifyAppForeground() {
        enqueueSyncRequest()
    }

    override fun notifyStaleScanRefreshAdvisory() {
        enqueueSyncRequest()
    }

    override fun notifyConnectivityRestored() {
        enqueueSyncRequest()
    }

    override suspend fun runSyncCycleNow() {
        try {
            runOneSyncCycle(failIfOffline = true)
        } catch (t: Throwable) {
            if (shouldScheduleRetry(t)) {
                scheduleBackoffRetry()
            }
            throw t
        }
    }

    private fun enqueueSyncRequest() {
        syncRequests.trySend(Unit)
    }

    private suspend fun runBackgroundSyncCycle() {
        try {
            runOneSyncCycle(failIfOffline = false)
        } catch (t: Throwable) {
            if (t is CancellationException) {
                throw t
            }
            if (shouldScheduleRetry(t)) {
                scheduleBackoffRetry()
            }
        }
    }

    private suspend fun runOneSyncCycle(failIfOffline: Boolean = false) {
        if (!connectivityMonitor.isOnline.value) {
            if (failIfOffline) {
                throw NonRetryableSyncException("Cannot sync while offline.")
            }
            return
        }

        val session =
            withContext(Dispatchers.IO) {
                sessionRepository.currentSession()
            }
                ?: if (failIfOffline) {
                    throw NonRetryableSyncException("No active session. Login before syncing.")
                } else {
                    return
                }

        val mode = resolveMode(session.eventId)
        try {
            withContext(Dispatchers.IO) {
                syncRepository.syncAttendees(mode)
            }
        } catch (pagination: SyncPaginationException) {
            sessionIntegrityFailures += 1
            throw pagination
        }
        sessionIntegrityFailures = 0
    }

    private fun shouldScheduleRetry(t: Throwable): Boolean =
        t !is NonRetryableSyncException && t !is CancellationException

    private class NonRetryableSyncException(
        message: String
    ) : IllegalStateException(message)

    private fun scheduleBackoffRetry() {
        retryJob?.cancel()
        retryJob =
            scope.launch {
                val status = syncRepository.currentSyncStatus()
                val transport = status?.consecutiveFailures ?: 0
                val integrity = status?.consecutiveIntegrityFailures ?: 0
                val failures = max(transport, integrity).coerceAtLeast(1)
                val idx = (failures - 1).coerceIn(0, config.backoffScheduleMs.lastIndex)
                val delayMs = config.backoffScheduleMs[idx]
                delay(delayMs)
                if (connectivityMonitor.isOnline.value) {
                    enqueueSyncRequest()
                }
            }
    }

    private suspend fun resolveMode(eventId: Long): AttendeeSyncMode {
        val status =
            withContext(Dispatchers.IO) {
                syncRepository.currentSyncStatus()
            }
                ?: return AttendeeSyncMode.INCREMENTAL

        if (status.eventId != eventId) {
            return AttendeeSyncMode.INCREMENTAL
        }

        if (status.consecutiveIntegrityFailures >= 2) {
            return AttendeeSyncMode.FULL_RECONCILE
        }

        if (sessionIntegrityFailures >= 3) {
            return AttendeeSyncMode.FULL_RECONCILE
        }

        val lastFull =
            status.lastFullReconcileAt?.let {
                runCatching { Instant.parse(it) }.getOrNull()
            }
        val needsTimeBasedFull =
            lastFull == null ||
                Duration.between(lastFull, clock.instant()) > Duration.ofMillis(config.fullReconcileWallClockMs)
        if (needsTimeBasedFull) {
            return AttendeeSyncMode.FULL_RECONCILE
        }

        if (status.incrementalCyclesSinceFullReconcile >= config.fullReconcileEveryIncrementalCycles) {
            return AttendeeSyncMode.FULL_RECONCILE
        }

        return AttendeeSyncMode.INCREMENTAL
    }
}
