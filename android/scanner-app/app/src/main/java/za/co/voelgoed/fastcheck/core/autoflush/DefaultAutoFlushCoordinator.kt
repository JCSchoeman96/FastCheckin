package za.co.voelgoed.fastcheck.core.autoflush

import java.time.Clock
import javax.inject.Inject
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlin.random.Random
import za.co.voelgoed.fastcheck.core.connectivity.ConnectivityMonitor
import za.co.voelgoed.fastcheck.data.repository.MobileScanRepository
import za.co.voelgoed.fastcheck.data.repository.FlushInvocationResult
import za.co.voelgoed.fastcheck.domain.model.FlushExecutionStatus
import za.co.voelgoed.fastcheck.domain.usecase.FlushQueuedScansUseCase
import za.co.voelgoed.fastcheck.core.session.AuthenticatedEventContextStore

class DefaultAutoFlushCoordinator @Inject constructor(
    private val flushQueuedScansUseCase: FlushQueuedScansUseCase,
    private val mobileScanRepository: MobileScanRepository,
    private val connectivityProvider: ConnectivityProvider,
    private val connectivityMonitor: ConnectivityMonitor,
    private val clock: Clock,
    private val contextStore: AuthenticatedEventContextStore = DefaultCoordinatorTestContextStore,
    private val maxBatchSize: Int = AutoFlushBatchPolicy.DEFAULT_BATCH_SIZE,
    private val afterEnqueueDebounceMs: Long = 250,
    private val retryBackoff: RetryBackoff =
        FullJitterExponentialBackoff(
            baseDelayMs = 1_000,
            capDelayMs = 60_000,
            nextRandomLong = { boundExclusive -> Random.nextLong(boundExclusive) }
        ),
    private val maxRetryAttempts: Int = 5,
    coordinatorDispatcher: CoroutineDispatcher = Dispatchers.IO
) : AutoFlushCoordinator, AutoCloseable {

    private val coordinatorScope =
        CoroutineScope(SupervisorJob() + coordinatorDispatcher)

    private val _state = MutableStateFlow(AutoFlushCoordinatorState())
    override val state: StateFlow<AutoFlushCoordinatorState> = _state

    private val mutex = Mutex()
    @Volatile
    private var flushRequestedWhileBusy: Boolean = false
    private var identityRequestedWhileBusy: za.co.voelgoed.fastcheck.core.session.AuthenticatedEventIdentity? = null

    private var flushJob: Job? = null
    private var scheduledStartJob: Job? = null
    private var pendingRetryJob: Job? = null
    private var retryAttempt: Int = 0
    private var currentBatchSize: Int = AutoFlushBatchPolicy.clamp(maxBatchSize)
    private var consecutiveHealthyFlushes: Int = 0

    init {
        coordinatorScope.launch {
            var lastOnline = connectivityMonitor.isOnline.value
            connectivityMonitor.isOnline.collectLatest { online ->
                val restored = !lastOnline && online
                lastOnline = online
                if (!restored) return@collectLatest

                val eventId = contextStore.currentIdentity()?.eventId ?: return@collectLatest
                val hasBacklog = mobileScanRepository.pendingQueueDepth(eventId) > 0
                if (!hasBacklog) return@collectLatest

                requestFlush(AutoFlushTrigger.ConnectivityRestored)
            }
        }
    }

    override fun close() {
        coordinatorScope.cancel()
    }

    private fun clearRetryState() {
        _state.value =
            _state.value.copy(
                isRetryScheduled = false,
                retryAttempt = 0,
                nextRetryAtEpochMs = null
            )
    }

    private fun setRetryState(attempt: Int, delayMs: Long) {
        _state.value =
            _state.value.copy(
                isRetryScheduled = true,
                retryAttempt = attempt,
                nextRetryAtEpochMs = clock.millis() + delayMs
            )
    }

    override fun requestFlush(trigger: AutoFlushTrigger) {
        coordinatorScope.launch {
            val identity = contextStore.currentIdentity() ?: return@launch
            val startedOrScheduled: Boolean =
                mutex.withLock {
                    if (flushJob?.isActive == true) {
                        if (_state.value.identity != identity) {
                            identityRequestedWhileBusy = identity
                            return@withLock false
                        }
                        // If we're already flushing, never start a concurrent run.
                        // However, immediate triggers should still cancel any pending
                        // debounce/retry so we don't fire redundant work later.
                        if (trigger != AutoFlushTrigger.AfterEnqueue) {
                            scheduledStartJob?.cancel()
                            scheduledStartJob = null
                            pendingRetryJob?.cancel()
                            pendingRetryJob = null
                            retryAttempt = 0
                            clearRetryState()
                        }

                        flushRequestedWhileBusy = true
                        return@withLock false
                    }

                    when (trigger) {
                        AutoFlushTrigger.Manual -> {
                            scheduledStartJob?.cancel()
                            scheduledStartJob = null
                            pendingRetryJob?.cancel()
                            pendingRetryJob = null
                            retryAttempt = 0
                            clearRetryState()

                            flushJob =
                                coordinatorScope.launch {
                                    startFlushLoop(identity)
                                }
                            true
                        }

                        AutoFlushTrigger.ConnectivityRestored,
                        AutoFlushTrigger.ForegroundResume,
                        AutoFlushTrigger.PostLogin,
                        AutoFlushTrigger.PostSync -> {
                            scheduledStartJob?.cancel()
                            scheduledStartJob = null
                            pendingRetryJob?.cancel()
                            pendingRetryJob = null
                            retryAttempt = 0
                            clearRetryState()

                            flushJob =
                                coordinatorScope.launch {
                                    startFlushLoop(identity)
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
                                                startFlushLoop(identity)
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

    private suspend fun startFlushLoop(identity: za.co.voelgoed.fastcheck.core.session.AuthenticatedEventIdentity) {
        try {
            while (true) {
                if (contextStore.currentIdentity() != identity) return
                _state.value =
                    _state.value.copy(
                        isFlushing = true,
                        isRetryScheduled = false,
                        nextRetryAtEpochMs = null,
                        identity = identity
                    )
                val invocation = flushQueuedScansUseCase.run(maxBatchSize = currentBatchSize)
                if (invocation == FlushInvocationResult.SkippedNoSession) return
                invocation as FlushInvocationResult.Attempted
                val report = invocation.report
                if (contextStore.currentIdentity() != identity) return
                adaptBatchSize(report)

                _state.value =
                    _state.value.copy(
                        isFlushing = false,
                        lastFlushReport = report
                    )

                if (report.uploadedCount > 0) {
                    mutex.withLock {
                        pendingRetryJob?.cancel()
                        pendingRetryJob = null
                        retryAttempt = 0
                    }
                    clearRetryState()
                }

                val madeProgress = report.uploadedCount > 0
                if (report.executionStatus == FlushExecutionStatus.RETRYABLE_FAILURE && !madeProgress) {
                    val shouldRerunBecauseBusy =
                        mutex.withLock {
                            val rerun = flushRequestedWhileBusy
                            if (rerun) flushRequestedWhileBusy = false
                            rerun
                        }
                    if (shouldRerunBecauseBusy) {
                        // An immediate trigger arrived while we were flushing.
                        // Prefer an immediate follow-up run over scheduling a delayed retry.
                        continue
                    }

                    val shouldScheduleRetry =
                        mutex.withLock {
                            if (pendingRetryJob?.isActive == true) return@withLock false
                            if (retryAttempt >= maxRetryAttempts) return@withLock false

                            val attempt = retryAttempt + 1
                            val delayMs = report.retryAfterMillis?.takeIf { it > 0 } ?: retryBackoff.delayMs(attempt)
                            setRetryState(attempt = attempt, delayMs = delayMs)
                            pendingRetryJob =
                                coordinatorScope.launch {
                                    delay(delayMs)
                                    // Avoid dropping retries due to a race where the previous flushJob
                                    // is still "active" while unwinding (finally block, mutex, etc.).
                                    // If a flush is active, wait for it to finish, then re-check.
                                    val activeFlush: Job? =
                                        mutex.withLock {
                                            flushJob?.takeIf { it.isActive }
                                        }
                                    activeFlush?.join()

                                    mutex.withLock {
                                        if (flushJob?.isActive == true) return@withLock
                                        if (!connectivityProvider.isOnline()) return@withLock
                                        if (contextStore.currentIdentity() != identity) return@withLock

                                        // Consume attempt only when we actually start the retry execution.
                                        retryAttempt = attempt
                                        // Retry is no longer "scheduled" once execution begins.
                                        _state.value =
                                            _state.value.copy(
                                                isRetryScheduled = false,
                                                nextRetryAtEpochMs = null
                                            )
                                        flushJob =
                                            coordinatorScope.launch {
                                                startFlushLoop(identity)
                                            }
                                    }
                                }.also { job ->
                                    job.invokeOnCompletion {
                                        coordinatorScope.launch {
                                            mutex.withLock {
                                                if (pendingRetryJob === job) {
                                                    pendingRetryJob = null
                                                    // If we didn't start a retry run, clear scheduled retry state.
                                                    if (_state.value.isRetryScheduled) {
                                                        clearRetryState()
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            true
                        }

                    if (shouldScheduleRetry) {
                        break
                    }
                }

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

                        contextStore.currentIdentity() == identity &&
                            mobileScanRepository.pendingQueueDepth(identity.eventId) > 0
                    }

                if (!shouldRunAgain) {
                    break
                }
            }
        } finally {
            val nextIdentity = mutex.withLock {
                flushJob = null
                flushRequestedWhileBusy = false
                scheduledStartJob?.cancel()
                scheduledStartJob = null
                if (_state.value.identity == identity) {
                    _state.value = _state.value.copy(isFlushing = false)
                }
                identityRequestedWhileBusy.also { identityRequestedWhileBusy = null }
            }
            if (nextIdentity != null && contextStore.currentIdentity() == nextIdentity) {
                mutex.withLock {
                    if (flushJob?.isActive != true) {
                        flushJob = coordinatorScope.launch { startFlushLoop(nextIdentity) }
                    }
                }
            }
        }
    }

    private fun adaptBatchSize(report: za.co.voelgoed.fastcheck.domain.model.FlushReport) {
        if (report.executionStatus != FlushExecutionStatus.COMPLETED) {
            consecutiveHealthyFlushes = 0
        }

        when {
            report.retryAfterMillis != null || report.httpStatusCode == 429 -> {
                currentBatchSize =
                    AutoFlushBatchPolicy.clamp((currentBatchSize / 2).coerceAtLeast(AutoFlushBatchPolicy.MIN_BATCH_SIZE))
                consecutiveHealthyFlushes = 0
            }

            report.httpStatusCode == 503 -> {
                currentBatchSize = AutoFlushBatchPolicy.clamp(currentBatchSize - 10)
                consecutiveHealthyFlushes = 0
            }

            report.executionStatus == FlushExecutionStatus.RETRYABLE_FAILURE -> {
                currentBatchSize = AutoFlushBatchPolicy.clamp(currentBatchSize - 5)
                consecutiveHealthyFlushes = 0
            }

            report.executionStatus == FlushExecutionStatus.AUTH_EXPIRED -> {
                consecutiveHealthyFlushes = 0
            }

            report.executionStatus == FlushExecutionStatus.COMPLETED &&
                !report.backpressureObserved &&
                report.uploadedCount > 0 -> {
                consecutiveHealthyFlushes += 1
                if (consecutiveHealthyFlushes >= 2) {
                    currentBatchSize = AutoFlushBatchPolicy.clamp(currentBatchSize + 5)
                    consecutiveHealthyFlushes = 0
                }
            }

            else -> {
                consecutiveHealthyFlushes = 0
            }
        }
    }
}

private object DefaultCoordinatorTestContextStore : AuthenticatedEventContextStore {
    private val identity = za.co.voelgoed.fastcheck.core.session.AuthenticatedEventIdentity(0, 1)
    override suspend fun capture() = za.co.voelgoed.fastcheck.core.session.AuthenticatedEventContext(0, "test-only", 1, 0, Long.MAX_VALUE)
    override suspend fun currentIdentity() = identity
    override suspend fun replace(eventId: Long, bearerToken: String, authenticatedAtEpochMillis: Long, expiresAtEpochMillis: Long) = error("unsupported")
    override suspend fun clearIfGenerationMatches(sessionGeneration: Long) = false
    override suspend fun isCurrent(sessionGeneration: Long) = sessionGeneration == 1L
    override fun observeIdentity() = kotlinx.coroutines.flow.flowOf(identity)
}
