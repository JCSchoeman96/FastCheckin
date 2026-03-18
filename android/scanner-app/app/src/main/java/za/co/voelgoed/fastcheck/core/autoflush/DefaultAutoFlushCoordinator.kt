package za.co.voelgoed.fastcheck.core.autoflush

import java.time.Clock
import javax.inject.Inject
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import za.co.voelgoed.fastcheck.core.connectivity.ConnectivityMonitor
import za.co.voelgoed.fastcheck.data.repository.MobileScanRepository
import za.co.voelgoed.fastcheck.domain.usecase.FlushQueuedScansUseCase

class DefaultAutoFlushCoordinator @Inject constructor(
    private val flushQueuedScansUseCase: FlushQueuedScansUseCase,
    private val mobileScanRepository: MobileScanRepository,
    private val connectivityProvider: ConnectivityProvider,
    private val connectivityMonitor: ConnectivityMonitor,
    private val clock: Clock,
    private val maxBatchSize: Int = 25,
    private val afterEnqueueDebounceMs: Long = 250,
    coordinatorDispatcher: CoroutineDispatcher = Dispatchers.IO
) : AutoFlushCoordinator {

    private val coordinatorScope =
        CoroutineScope(SupervisorJob() + coordinatorDispatcher)

    private val _state = MutableStateFlow(AutoFlushCoordinatorState())
    override val state: StateFlow<AutoFlushCoordinatorState> = _state

    private val mutex = Mutex()
    @Volatile
    private var flushRequestedWhileBusy: Boolean = false

    private var flushJob: Job? = null
    private var scheduledStartJob: Job? = null

    init {
        coordinatorScope.launch {
            var lastOnline = connectivityMonitor.isOnline.value
            connectivityMonitor.isOnline.collectLatest { online ->
                val restored = !lastOnline && online
                lastOnline = online
                if (!restored) return@collectLatest

                val hasBacklog = mobileScanRepository.pendingQueueDepth() > 0
                if (!hasBacklog) return@collectLatest

                requestFlush(AutoFlushTrigger.ConnectivityRestored)
            }
        }
    }

    override fun requestFlush(trigger: AutoFlushTrigger) {
        coordinatorScope.launch {
            val startedOrScheduled: Boolean =
                mutex.withLock {
                    if (flushJob?.isActive == true) {
                        flushRequestedWhileBusy = true
                        return@withLock false
                    }

                    when (trigger) {
                        AutoFlushTrigger.Manual -> {
                            scheduledStartJob?.cancel()
                            scheduledStartJob = null

                            flushJob =
                                coordinatorScope.launch {
                                    startFlushLoop()
                                }
                            true
                        }

                        AutoFlushTrigger.ConnectivityRestored,
                        AutoFlushTrigger.ForegroundResume,
                        AutoFlushTrigger.PostLogin,
                        AutoFlushTrigger.PostSync -> {
                            scheduledStartJob?.cancel()
                            scheduledStartJob = null

                            flushJob =
                                coordinatorScope.launch {
                                    startFlushLoop()
                                }
                            true
                        }

                        AutoFlushTrigger.AfterEnqueue -> {
                            if (!connectivityProvider.isOnline()) {
                                return@withLock false
                            }

                            if (scheduledStartJob?.isActive == true) {
                                return@withLock false
                            }

                            scheduledStartJob =
                                coordinatorScope.launch {
                                    delay(afterEnqueueDebounceMs)
                                    mutex.withLock {
                                        // Recheck under mutex to avoid racing a manual flush start.
                                        if (flushJob?.isActive == true) return@withLock
                                        flushJob =
                                            coordinatorScope.launch {
                                                startFlushLoop()
                                            }
                                    }
                                }.also { job ->
                                    job.invokeOnCompletion {
                                        coordinatorScope.launch {
                                            mutex.withLock {
                                                if (scheduledStartJob === job) {
                                                    scheduledStartJob = null
                                                }
                                            }
                                        }
                                    }
                                }

                            true
                        }
                    }
                }

            if (!startedOrScheduled) return@launch
        }
    }

    private suspend fun startFlushLoop() {
        try {
            while (true) {
                _state.value = _state.value.copy(isFlushing = true)
                val report = flushQueuedScansUseCase.run(maxBatchSize = maxBatchSize)

                _state.value =
                    _state.value.copy(
                        isFlushing = false,
                        lastFlushReport = report
                    )

                val madeProgress = report.uploadedCount > 0
                val shouldRunAgain =
                    mutex.withLock {
                        val shouldRunBecauseBusy = flushRequestedWhileBusy
                        flushRequestedWhileBusy = false

                        if (shouldRunBecauseBusy) {
                            return@withLock true
                        }

                        if (!madeProgress) {
                            return@withLock false
                        }

                        mobileScanRepository.pendingQueueDepth() > 0
                    }

                if (!shouldRunAgain) {
                    break
                }
            }
        } finally {
            mutex.withLock {
                flushJob = null
                flushRequestedWhileBusy = false
                scheduledStartJob?.cancel()
                scheduledStartJob = null
                _state.value = _state.value.copy(isFlushing = false)
            }
        }
    }
}
