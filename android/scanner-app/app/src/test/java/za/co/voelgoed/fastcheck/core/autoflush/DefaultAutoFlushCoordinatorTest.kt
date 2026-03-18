package za.co.voelgoed.fastcheck.core.autoflush

import com.google.common.truth.Truth.assertThat
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Test
import za.co.voelgoed.fastcheck.core.connectivity.ConnectivityMonitor
import za.co.voelgoed.fastcheck.domain.model.FlushExecutionStatus
import za.co.voelgoed.fastcheck.domain.model.FlushReport

@OptIn(ExperimentalCoroutinesApi::class)
class DefaultAutoFlushCoordinatorTest {
    private val closeables = mutableListOf<AutoCloseable>()

    @After
    fun tearDown() {
        closeables.forEach { it.close() }
        closeables.clear()
    }

    private class RecordingFlushUseCase(
        private val reportProvider: suspend () -> FlushReport
    ) : za.co.voelgoed.fastcheck.domain.usecase.FlushQueuedScansUseCase {
        private val mutex = Mutex()
        private val _reports = mutableListOf<FlushReport>()
        val reports: List<FlushReport>
            get() = _reports.toList()
        private val _batchSizes = mutableListOf<Int>()
        val batchSizes: List<Int>
            get() = _batchSizes.toList()

        var maxConcurrentCalls: Int = 0
            private set
        private var inFlightCalls: Int = 0

        override suspend fun run(maxBatchSize: Int): FlushReport {
            mutex.withLock {
                inFlightCalls += 1
                maxConcurrentCalls = maxOf(maxConcurrentCalls, inFlightCalls)
                _batchSizes.add(maxBatchSize)
            }

            try {
                val report = reportProvider.invoke()
                mutex.withLock { _reports.add(report) }
                return report
            } finally {
                mutex.withLock { inFlightCalls -= 1 }
            }
        }
    }

    private class RecordingScanRepository : za.co.voelgoed.fastcheck.data.repository.MobileScanRepository {
        var depth: Int = 0

        override suspend fun queueScan(
            scan: za.co.voelgoed.fastcheck.domain.model.PendingScan
        ): za.co.voelgoed.fastcheck.domain.model.QueueCreationResult {
            throw UnsupportedOperationException()
        }

        override suspend fun flushQueuedScans(
            maxBatchSize: Int
        ): FlushReport {
            throw UnsupportedOperationException()
        }

        override suspend fun pendingQueueDepth(): Int = depth

        override suspend fun latestFlushReport(): FlushReport? = null
    }

    private class FakeConnectivityMonitor(initialOnline: Boolean) : ConnectivityMonitor {
        private val _isOnline = MutableStateFlow(initialOnline)
        override val isOnline: StateFlow<Boolean> = _isOnline

        fun setOnline(value: Boolean) {
            _isOnline.value = value
        }
    }

    @Test
    fun singleManualRequestRunsOnce() =
        runTest(StandardTestDispatcher()) {
            val useCase =
                RecordingFlushUseCase {
                    FlushReport(
                        executionStatus = FlushExecutionStatus.COMPLETED,
                        uploadedCount = 1
                    )
                }
            val repo = RecordingScanRepository()
            val monitor = FakeConnectivityMonitor(initialOnline = true)
            val coordinator =
                DefaultAutoFlushCoordinator(
                    flushQueuedScansUseCase = useCase,
                    mobileScanRepository = repo,
                    connectivityProvider = ConnectivityProvider { true },
                    connectivityMonitor = monitor,
                    clock = java.time.Clock.systemUTC(),
                    coordinatorDispatcher = StandardTestDispatcher(testScheduler)
                ).also { closeables += it }

            coordinator.requestFlush(AutoFlushTrigger.Manual)

            advanceUntilIdle()

            assertThat(useCase.reports).hasSize(1)
            assertThat(coordinator.state.value.isFlushing).isFalse()
        }

    @Test
    fun multipleRapidAfterEnqueueRequestsNeverOverlap() =
        runTest(StandardTestDispatcher()) {
            val useCase =
                RecordingFlushUseCase {
                    delay(50)
                    FlushReport(
                        executionStatus = FlushExecutionStatus.COMPLETED,
                        uploadedCount = 1
                    )
                }
            val repo = RecordingScanRepository().apply { depth = 0 }
            val monitor = FakeConnectivityMonitor(initialOnline = true)
            val coordinator =
                DefaultAutoFlushCoordinator(
                    flushQueuedScansUseCase = useCase,
                    mobileScanRepository = repo,
                    connectivityProvider = ConnectivityProvider { true },
                    connectivityMonitor = monitor,
                    clock = java.time.Clock.systemUTC(),
                    coordinatorDispatcher = StandardTestDispatcher(testScheduler)
                ).also { closeables += it }

            val jobs =
                (1..10).map {
                    async {
                        coordinator.requestFlush(AutoFlushTrigger.AfterEnqueue)
                    }
                }
            jobs.awaitAll()

            // AfterEnqueue starts are debounced while idle.
            advanceTimeBy(250)
            advanceUntilIdle()

            assertThat(useCase.maxConcurrentCalls).isEqualTo(1)
            assertThat(useCase.reports).isNotEmpty()
        }

    @Test
    fun requestWhileBusyCausesExactlyOneFollowUpRun() =
        runTest(StandardTestDispatcher()) {
            var callCount = 0
            val useCase =
                RecordingFlushUseCase {
                    callCount += 1
                    delay(50)
                    FlushReport(
                        executionStatus = FlushExecutionStatus.COMPLETED,
                        uploadedCount = 1
                    )
                }
            val repo =
                RecordingScanRepository().apply {
                    depth = 1
                }
            val monitor = FakeConnectivityMonitor(initialOnline = true)
            val coordinator =
                DefaultAutoFlushCoordinator(
                    flushQueuedScansUseCase = useCase,
                    mobileScanRepository = repo,
                    connectivityProvider = ConnectivityProvider { true },
                    connectivityMonitor = monitor,
                    clock = java.time.Clock.systemUTC(),
                    coordinatorDispatcher = StandardTestDispatcher(testScheduler)
                ).also { closeables += it }

            coordinator.requestFlush(AutoFlushTrigger.Manual)
            coordinator.requestFlush(AutoFlushTrigger.AfterEnqueue)
            coordinator.requestFlush(AutoFlushTrigger.AfterEnqueue)

            // After first run, simulate that queue is now empty so a second run happens only
            // because requestWhileBusy set the pending flag, not because depth remains.
            repo.depth = 0

            advanceUntilIdle()

            assertThat(useCase.reports).hasSize(2)
            assertThat(useCase.maxConcurrentCalls).isEqualTo(1)
        }

    @Test
    fun noProgressFailureWithRemainingDepthDoesNotLoopImmediately() =
        runTest(StandardTestDispatcher()) {
            val useCase =
                RecordingFlushUseCase {
                    FlushReport(
                        executionStatus = FlushExecutionStatus.RETRYABLE_FAILURE,
                        uploadedCount = 0
                    )
                }
            val repo = RecordingScanRepository().apply { depth = 10 }
            val monitor = FakeConnectivityMonitor(initialOnline = true)
            val coordinator =
                DefaultAutoFlushCoordinator(
                    flushQueuedScansUseCase = useCase,
                    mobileScanRepository = repo,
                    connectivityProvider = ConnectivityProvider { true },
                    connectivityMonitor = monitor,
                    clock = java.time.Clock.systemUTC(),
                    coordinatorDispatcher = StandardTestDispatcher(testScheduler)
                ).also { closeables += it }

            coordinator.requestFlush(AutoFlushTrigger.Manual)
            // Do not advance time here; we only assert there's no immediate loop.
            runCurrent()

            assertThat(useCase.reports).hasSize(1)
        }

    @Test
    fun afterEnqueueOfflineSkipsFlush() =
        runTest(StandardTestDispatcher()) {
            val useCase =
                RecordingFlushUseCase {
                    FlushReport(
                        executionStatus = FlushExecutionStatus.COMPLETED,
                        uploadedCount = 1
                    )
                }
            val repo = RecordingScanRepository().apply { depth = 1 }
            val monitor = FakeConnectivityMonitor(initialOnline = false)
            val coordinator =
                DefaultAutoFlushCoordinator(
                    flushQueuedScansUseCase = useCase,
                    mobileScanRepository = repo,
                    connectivityProvider = ConnectivityProvider { false },
                    connectivityMonitor = monitor,
                    clock = java.time.Clock.systemUTC(),
                    coordinatorDispatcher = StandardTestDispatcher(testScheduler)
                ).also { closeables += it }

            coordinator.requestFlush(AutoFlushTrigger.AfterEnqueue)
            advanceUntilIdle()

            assertThat(useCase.reports).isEmpty()
        }

    @Test
    fun afterEnqueueDebouncesInitialStart_only() =
        runTest(StandardTestDispatcher()) {
            val useCase =
                RecordingFlushUseCase {
                    FlushReport(
                        executionStatus = FlushExecutionStatus.COMPLETED,
                        uploadedCount = 1
                    )
                }
            val repo = RecordingScanRepository().apply { depth = 0 }
            val monitor = FakeConnectivityMonitor(initialOnline = true)
            val coordinator =
                DefaultAutoFlushCoordinator(
                    flushQueuedScansUseCase = useCase,
                    mobileScanRepository = repo,
                    connectivityProvider = ConnectivityProvider { true },
                    connectivityMonitor = monitor,
                    clock = java.time.Clock.systemUTC(),
                    coordinatorDispatcher = StandardTestDispatcher(testScheduler)
                ).also { closeables += it }

            coordinator.requestFlush(AutoFlushTrigger.AfterEnqueue)

            runCurrent()
            advanceTimeBy(249)
            runCurrent()
            assertThat(useCase.reports).isEmpty()

            advanceTimeBy(1)
            runCurrent()
            assertThat(useCase.reports).hasSize(1)
        }

    @Test
    fun afterEnqueueBurstCoalesces_singleScheduledJob() =
        runTest(StandardTestDispatcher()) {
            val useCase =
                RecordingFlushUseCase {
                    FlushReport(
                        executionStatus = FlushExecutionStatus.COMPLETED,
                        uploadedCount = 1
                    )
                }
            val repo = RecordingScanRepository().apply { depth = 0 }
            val monitor = FakeConnectivityMonitor(initialOnline = true)
            val coordinator =
                DefaultAutoFlushCoordinator(
                    flushQueuedScansUseCase = useCase,
                    mobileScanRepository = repo,
                    connectivityProvider = ConnectivityProvider { true },
                    connectivityMonitor = monitor,
                    clock = java.time.Clock.systemUTC(),
                    coordinatorDispatcher = StandardTestDispatcher(testScheduler)
                ).also { closeables += it }

            repeat(10) {
                coordinator.requestFlush(AutoFlushTrigger.AfterEnqueue)
            }

            runCurrent()
            advanceTimeBy(250)
            runCurrent()

            assertThat(useCase.reports).hasSize(1)
        }

    @Test
    fun manualDuringPendingDebounce_startsImmediately_andCancelsDelayedStart() =
        runTest(StandardTestDispatcher()) {
            val useCase =
                RecordingFlushUseCase {
                    FlushReport(
                        executionStatus = FlushExecutionStatus.COMPLETED,
                        uploadedCount = 1
                    )
                }
            val repo = RecordingScanRepository().apply { depth = 0 }
            val monitor = FakeConnectivityMonitor(initialOnline = true)
            val coordinator =
                DefaultAutoFlushCoordinator(
                    flushQueuedScansUseCase = useCase,
                    mobileScanRepository = repo,
                    connectivityProvider = ConnectivityProvider { true },
                    connectivityMonitor = monitor,
                    clock = java.time.Clock.systemUTC(),
                    coordinatorDispatcher = StandardTestDispatcher(testScheduler)
                ).also { closeables += it }

            coordinator.requestFlush(AutoFlushTrigger.AfterEnqueue)
            runCurrent()
            advanceTimeBy(100)
            runCurrent()

            coordinator.requestFlush(AutoFlushTrigger.Manual)
            advanceUntilIdle()

            assertThat(useCase.reports).hasSize(1)

            // Ensure the delayed debounce start does not trigger a redundant second flush.
            advanceTimeBy(1_000)
            runCurrent()
            assertThat(useCase.reports).hasSize(1)
        }

    @Test
    fun boundedBatching_drainsInMultipleImmediateRuns_noDebounceBetweenRuns() =
        runTest(StandardTestDispatcher()) {
            var invocation = 0
            val repo = RecordingScanRepository().apply { depth = 60 }
            val monitor = FakeConnectivityMonitor(initialOnline = true)
            val useCase =
                RecordingFlushUseCase {
                    invocation += 1
                    check(invocation <= 10) { "Flush loop ran too many times: invocation=$invocation" }

                    repo.depth =
                        when (invocation) {
                            1 -> 35
                            2 -> 10
                            3 -> 0
                            else -> 0
                        }

                    FlushReport(
                        executionStatus = FlushExecutionStatus.COMPLETED,
                        uploadedCount = 1
                    )
                }
            val coordinator =
                DefaultAutoFlushCoordinator(
                    flushQueuedScansUseCase = useCase,
                    mobileScanRepository = repo,
                    connectivityProvider = ConnectivityProvider { true },
                    connectivityMonitor = monitor,
                    clock = java.time.Clock.systemUTC(),
                    maxBatchSize = 25,
                    afterEnqueueDebounceMs = 250,
                    coordinatorDispatcher = StandardTestDispatcher(testScheduler)
                ).also { closeables += it }

            coordinator.requestFlush(AutoFlushTrigger.Manual)
            advanceUntilIdle()

            assertThat(invocation).isEqualTo(3)
            assertThat(useCase.batchSizes).containsExactly(25, 25, 25).inOrder()
            assertThat(useCase.maxConcurrentCalls).isEqualTo(1)
        }

    @Test
    fun madeProgressWithRemainingDepthRunsSecondTime() =
        runTest(StandardTestDispatcher()) {
            var invocation = 0
            val repo =
                RecordingScanRepository().apply {
                    depth = 2
                }
            val monitor = FakeConnectivityMonitor(initialOnline = true)
            val useCase =
                RecordingFlushUseCase {
                    invocation += 1
                    check(invocation <= 3) { "Flush loop ran too many times: invocation=$invocation" }

                    // Deterministic depth progression for the coordinator's "should run again" check:
                    // - after 1st flush: depth still present -> run again
                    // - after 2nd flush: depth empty -> stop
                    repo.depth =
                        when (invocation) {
                            1 -> 1
                            2 -> 0
                            else -> 0
                        }
                    FlushReport(
                        executionStatus = FlushExecutionStatus.COMPLETED,
                        uploadedCount = 1
                    )
                }
            val coordinator =
                DefaultAutoFlushCoordinator(
                    flushQueuedScansUseCase = useCase,
                    mobileScanRepository = repo,
                    connectivityProvider = ConnectivityProvider { true },
                    connectivityMonitor = monitor,
                    clock = java.time.Clock.systemUTC(),
                    coordinatorDispatcher = StandardTestDispatcher(testScheduler)
                ).also { closeables += it }

            coordinator.requestFlush(AutoFlushTrigger.Manual)

            advanceUntilIdle()

            assertThat(invocation).isEqualTo(2)
            assertThat(useCase.reports).hasSize(2)
            assertThat(useCase.maxConcurrentCalls).isEqualTo(1)
        }

    @Test
    fun offlineToOnline_withBacklog_triggersImmediateFlush_notDebounced() =
        runTest(StandardTestDispatcher()) {
            val monitor = FakeConnectivityMonitor(initialOnline = false)
            val repo = RecordingScanRepository().apply { depth = 1 }
            val useCase =
                RecordingFlushUseCase {
                    FlushReport(
                        executionStatus = FlushExecutionStatus.COMPLETED,
                        uploadedCount = 0
                    )
                }
            DefaultAutoFlushCoordinator(
                flushQueuedScansUseCase = useCase,
                mobileScanRepository = repo,
                connectivityProvider = ConnectivityProvider { monitor.isOnline.value },
                connectivityMonitor = monitor,
                clock = java.time.Clock.systemUTC(),
                coordinatorDispatcher = StandardTestDispatcher(testScheduler)
            ).also { closeables += it }

            runCurrent()
            assertThat(useCase.reports).isEmpty()

            // Connection-restored should be immediate and not depend on AfterEnqueue debounce.
            monitor.setOnline(true)
            runCurrent()
            advanceUntilIdle()

            assertThat(useCase.reports).hasSize(1)
        }

    @Test
    fun offlineToOnline_emptyQueue_doesNotFlush() =
        runTest(StandardTestDispatcher()) {
            val monitor = FakeConnectivityMonitor(initialOnline = false)
            val repo = RecordingScanRepository().apply { depth = 0 }
            val useCase =
                RecordingFlushUseCase {
                    FlushReport(
                        executionStatus = FlushExecutionStatus.COMPLETED,
                        uploadedCount = 0
                    )
                }
            DefaultAutoFlushCoordinator(
                flushQueuedScansUseCase = useCase,
                mobileScanRepository = repo,
                connectivityProvider = ConnectivityProvider { monitor.isOnline.value },
                connectivityMonitor = monitor,
                clock = java.time.Clock.systemUTC(),
                coordinatorDispatcher = StandardTestDispatcher(testScheduler)
            ).also { closeables += it }

            // Ensure the coordinator's connectivity subscription is active
            // before we flip online (otherwise the false->true transition is missed).
            runCurrent()

            monitor.setOnline(true)
            runCurrent()
            advanceUntilIdle()

            assertThat(useCase.reports).isEmpty()
        }

    @Test
    fun repeatedOnlineEvents_doNotOverlapFlushes() =
        runTest(StandardTestDispatcher()) {
            val monitor = FakeConnectivityMonitor(initialOnline = false)
            val repo = RecordingScanRepository().apply { depth = 1 }
            var calls = 0
            val useCase =
                RecordingFlushUseCase {
                    calls += 1
                    check(calls <= 3) { "Unexpected flush loop: calls=$calls" }
                    delay(50)
                    FlushReport(
                        executionStatus = FlushExecutionStatus.COMPLETED,
                        uploadedCount = 0
                    )
                }
            DefaultAutoFlushCoordinator(
                flushQueuedScansUseCase = useCase,
                mobileScanRepository = repo,
                connectivityProvider = ConnectivityProvider { monitor.isOnline.value },
                connectivityMonitor = monitor,
                clock = java.time.Clock.systemUTC(),
                coordinatorDispatcher = StandardTestDispatcher(testScheduler)
            ).also { closeables += it }

            // Ensure the coordinator's connectivity subscription is active
            // before we flip online (otherwise the false->true transition is missed).
            runCurrent()

            monitor.setOnline(true)
            runCurrent()

            monitor.setOnline(false)
            monitor.setOnline(true)
            runCurrent()

            advanceUntilIdle()

            assertThat(useCase.maxConcurrentCalls).isEqualTo(1)
            assertThat(useCase.reports).isNotEmpty()
        }

    @Test
    fun noOverlappingRetries() =
        runTest(StandardTestDispatcher()) {
            val monitor = FakeConnectivityMonitor(initialOnline = true)
            val repo = RecordingScanRepository().apply { depth = 1 }
            var calls = 0
            val useCase =
                RecordingFlushUseCase {
                    calls += 1
                    delay(50)
                    FlushReport(
                        executionStatus = FlushExecutionStatus.RETRYABLE_FAILURE,
                        uploadedCount = 0
                    )
                }

            // Always retry immediately (0ms) to stress overlap safety.
            val backoff = RetryBackoff { _ -> 0L }

            val coordinator =
                DefaultAutoFlushCoordinator(
                    flushQueuedScansUseCase = useCase,
                    mobileScanRepository = repo,
                    connectivityProvider = ConnectivityProvider { monitor.isOnline.value },
                    connectivityMonitor = monitor,
                    clock = java.time.Clock.systemUTC(),
                    retryBackoff = backoff,
                    maxRetryAttempts = 2,
                    coordinatorDispatcher = StandardTestDispatcher(testScheduler)
                ).also { closeables += it }

            coordinator.requestFlush(AutoFlushTrigger.Manual)

            advanceUntilIdle()

            assertThat(useCase.maxConcurrentCalls).isEqualTo(1)
            assertThat(calls).isAtLeast(1)
        }

    @Test
    fun boundedBackoffGrowth_capped_andStopsAfter5() =
        runTest(StandardTestDispatcher()) {
            val monitor = FakeConnectivityMonitor(initialOnline = true)
            val repo = RecordingScanRepository().apply { depth = 1 }
            var calls = 0
            val useCase =
                RecordingFlushUseCase {
                    calls += 1
                    FlushReport(
                        executionStatus = FlushExecutionStatus.RETRYABLE_FAILURE,
                        uploadedCount = 0
                    )
                }

            // Deterministic increasing delays (simulate exponential with cap).
            val delays = listOf(1_000L, 2_000L, 4_000L, 8_000L, 60_000L)
            val backoff = RetryBackoff { attempt -> delays[attempt - 1] }

            val coordinator =
                DefaultAutoFlushCoordinator(
                    flushQueuedScansUseCase = useCase,
                    mobileScanRepository = repo,
                    connectivityProvider = ConnectivityProvider { monitor.isOnline.value },
                    connectivityMonitor = monitor,
                    clock = java.time.Clock.systemUTC(),
                    retryBackoff = backoff,
                    maxRetryAttempts = 5,
                    coordinatorDispatcher = StandardTestDispatcher(testScheduler)
                ).also { closeables += it }

            coordinator.requestFlush(AutoFlushTrigger.Manual)

            runCurrent()
            assertThat(calls).isEqualTo(1)

            advanceTimeBy(1_000)
            runCurrent()
            assertThat(calls).isEqualTo(2)

            advanceTimeBy(2_000)
            runCurrent()
            assertThat(calls).isEqualTo(3)

            advanceTimeBy(4_000)
            runCurrent()
            assertThat(calls).isEqualTo(4)

            advanceTimeBy(8_000)
            runCurrent()
            assertThat(calls).isEqualTo(5)

            // 5th retry scheduled at capped 60s, but max attempts reached after it executes.
            advanceTimeBy(60_000)
            runCurrent()
            assertThat(calls).isEqualTo(6)

            // No more retries after max attempts.
            advanceTimeBy(120_000)
            runCurrent()
            assertThat(calls).isEqualTo(6)
        }

    @Test
    fun offlinePausesRetry_doesNotConsumeAttempt() =
        runTest(StandardTestDispatcher()) {
            val monitor = FakeConnectivityMonitor(initialOnline = true)
            val repo = RecordingScanRepository().apply { depth = 1 }
            var calls = 0
            val useCase =
                RecordingFlushUseCase {
                    calls += 1
                    FlushReport(
                        executionStatus = FlushExecutionStatus.RETRYABLE_FAILURE,
                        uploadedCount = 0
                    )
                }

            val backoff = RetryBackoff { _ -> 1_000L }

            val coordinator =
                DefaultAutoFlushCoordinator(
                    flushQueuedScansUseCase = useCase,
                    mobileScanRepository = repo,
                    connectivityProvider = ConnectivityProvider { monitor.isOnline.value },
                    connectivityMonitor = monitor,
                    clock = java.time.Clock.systemUTC(),
                    retryBackoff = backoff,
                    maxRetryAttempts = 5,
                    coordinatorDispatcher = StandardTestDispatcher(testScheduler)
                )

            coordinator.requestFlush(AutoFlushTrigger.Manual)
            runCurrent()
            assertThat(calls).isEqualTo(1)

            // Go offline before the retry would fire.
            monitor.setOnline(false)
            advanceTimeBy(1_000)
            runCurrent()
            // Retry should not execute while offline.
            assertThat(calls).isEqualTo(1)

            // Restore connectivity: A4 trigger should cause an immediate flush.
            monitor.setOnline(true)
            runCurrent()
            runCurrent()
            assertThat(calls).isEqualTo(2)
        }

    @Test
    fun progressResetsRetryState() =
        runTest(StandardTestDispatcher()) {
            val monitor = FakeConnectivityMonitor(initialOnline = true)
            val repo = RecordingScanRepository().apply { depth = 1 }
            var calls = 0
            val useCase =
                RecordingFlushUseCase {
                    calls += 1
                    check(calls <= 5) { "Unexpected flush loop: calls=$calls" }
                    when (calls) {
                        1, 2 ->
                            FlushReport(
                                executionStatus = FlushExecutionStatus.RETRYABLE_FAILURE,
                                uploadedCount = 0
                            )
                        else -> {
                            repo.depth = 0
                            FlushReport(
                                executionStatus = FlushExecutionStatus.COMPLETED,
                                uploadedCount = 1
                            )
                        }
                    }
                }
            val backoff = RetryBackoff { _ -> 1_000L }

            val coordinator =
                DefaultAutoFlushCoordinator(
                    flushQueuedScansUseCase = useCase,
                    mobileScanRepository = repo,
                    connectivityProvider = ConnectivityProvider { monitor.isOnline.value },
                    connectivityMonitor = monitor,
                    clock = java.time.Clock.systemUTC(),
                    retryBackoff = backoff,
                    maxRetryAttempts = 5,
                    coordinatorDispatcher = StandardTestDispatcher(testScheduler)
                ).also { closeables += it }

            coordinator.requestFlush(AutoFlushTrigger.Manual)

            runCurrent()
            assertThat(calls).isEqualTo(1)

            advanceTimeBy(1_000)
            runCurrent()
            assertThat(calls).isEqualTo(2)

            advanceTimeBy(1_000)
            runCurrent()
            assertThat(calls).isEqualTo(3)

            // Progress occurred; no more retries should be scheduled.
            advanceTimeBy(60_000)
            runCurrent()
            assertThat(calls).isEqualTo(3)
        }

    @Test
    fun manualCancelsPendingRetry_andStartsImmediate() =
        runTest(StandardTestDispatcher()) {
            val monitor = FakeConnectivityMonitor(initialOnline = true)
            val repo = RecordingScanRepository().apply { depth = 1 }
            var calls = 0
            val useCase =
                RecordingFlushUseCase {
                    calls += 1
                    if (calls == 1) {
                        FlushReport(
                            executionStatus = FlushExecutionStatus.RETRYABLE_FAILURE,
                            uploadedCount = 0
                        )
                    } else {
                        FlushReport(
                            executionStatus = FlushExecutionStatus.COMPLETED,
                            uploadedCount = 0
                        )
                    }
                }
            val backoff = RetryBackoff { _ -> 60_000L }

            val coordinator =
                DefaultAutoFlushCoordinator(
                    flushQueuedScansUseCase = useCase,
                    mobileScanRepository = repo,
                    connectivityProvider = ConnectivityProvider { monitor.isOnline.value },
                    connectivityMonitor = monitor,
                    clock = java.time.Clock.systemUTC(),
                    retryBackoff = backoff,
                    maxRetryAttempts = 5,
                    coordinatorDispatcher = StandardTestDispatcher(testScheduler)
                ).also { closeables += it }

            coordinator.requestFlush(AutoFlushTrigger.Manual)
            runCurrent()
            assertThat(calls).isEqualTo(1)

            // Manual flush should cancel the pending retry and run immediately.
            coordinator.requestFlush(AutoFlushTrigger.Manual)
            runCurrent()
            advanceTimeBy(1)
            runCurrent()
            assertThat(calls).isEqualTo(2)

            // Pending retry should not fire later.
            advanceTimeBy(60_000)
            runCurrent()
            assertThat(calls).isEqualTo(2)
        }

    @Test
    fun foregroundResumeCancelsPendingRetry_andStartsImmediate() =
        runTest(StandardTestDispatcher()) {
            val monitor = FakeConnectivityMonitor(initialOnline = true)
            val repo = RecordingScanRepository().apply { depth = 1 }
            var calls = 0
            val useCase =
                RecordingFlushUseCase {
                    calls += 1
                    if (calls == 1) {
                        FlushReport(
                            executionStatus = FlushExecutionStatus.RETRYABLE_FAILURE,
                            uploadedCount = 0
                        )
                    } else {
                        FlushReport(
                            executionStatus = FlushExecutionStatus.COMPLETED,
                            uploadedCount = 0
                        )
                    }
                }
            val backoff = RetryBackoff { _ -> 60_000L }

            val coordinator =
                DefaultAutoFlushCoordinator(
                    flushQueuedScansUseCase = useCase,
                    mobileScanRepository = repo,
                    connectivityProvider = ConnectivityProvider { monitor.isOnline.value },
                    connectivityMonitor = monitor,
                    clock = java.time.Clock.systemUTC(),
                    retryBackoff = backoff,
                    maxRetryAttempts = 5,
                    coordinatorDispatcher = StandardTestDispatcher(testScheduler)
                ).also { closeables += it }

            coordinator.requestFlush(AutoFlushTrigger.Manual)
            runCurrent()
            assertThat(calls).isEqualTo(1)

            coordinator.requestFlush(AutoFlushTrigger.ForegroundResume)
            runCurrent()
            advanceTimeBy(1)
            runCurrent()
            assertThat(calls).isEqualTo(2)

            // Pending retry should not fire later.
            advanceTimeBy(60_000)
            runCurrent()
            assertThat(calls).isEqualTo(2)
        }
}

