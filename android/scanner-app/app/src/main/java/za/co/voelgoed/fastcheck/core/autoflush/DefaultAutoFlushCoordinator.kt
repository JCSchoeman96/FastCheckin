package za.co.voelgoed.fastcheck.core.autoflush

import java.time.Clock
import javax.inject.Inject
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import za.co.voelgoed.fastcheck.data.repository.MobileScanRepository
import za.co.voelgoed.fastcheck.domain.usecase.FlushQueuedScansUseCase

class DefaultAutoFlushCoordinator @Inject constructor(
    private val flushQueuedScansUseCase: FlushQueuedScansUseCase,
    private val mobileScanRepository: MobileScanRepository,
    private val connectivityProvider: ConnectivityProvider,
    private val clock: Clock,
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

    override fun requestFlush(trigger: AutoFlushTrigger) {
        coordinatorScope.launch {
            val shouldStartFlush: Boolean =
                mutex.withLock {
                    if (flushJob?.isActive == true) {
                        flushRequestedWhileBusy = true
                        return@withLock false
                    }

                    if (trigger is AutoFlushTrigger.AfterEnqueue && !connectivityProvider.isOnline()) {
                        return@withLock false
                    }

                    flushJob =
                        coordinatorScope.launch {
                            startFlushLoop()
                        }
                    true
                }

            if (!shouldStartFlush) return@launch
        }
    }

    private suspend fun startFlushLoop() {
        try {
            while (true) {
                _state.value = _state.value.copy(isFlushing = true)
                val report = flushQueuedScansUseCase.run(maxBatchSize = 50)

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
                _state.value = _state.value.copy(isFlushing = false)
            }
        }
    }
}
