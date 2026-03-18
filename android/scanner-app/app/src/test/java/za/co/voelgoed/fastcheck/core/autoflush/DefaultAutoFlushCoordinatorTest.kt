package za.co.voelgoed.fastcheck.core.autoflush

import com.google.common.truth.Truth.assertThat
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.delay
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.runTest
import org.junit.Test
import za.co.voelgoed.fastcheck.domain.model.FlushExecutionStatus
import za.co.voelgoed.fastcheck.domain.model.FlushReport

@OptIn(ExperimentalCoroutinesApi::class)
class DefaultAutoFlushCoordinatorTest {

    private class RecordingFlushUseCase(
        private val reportProvider: suspend () -> FlushReport
    ) : za.co.voelgoed.fastcheck.domain.usecase.FlushQueuedScansUseCase {
        private val mutex = Mutex()
        private val _reports = mutableListOf<FlushReport>()
        val reports: List<FlushReport>
            get() = _reports.toList()

        var maxConcurrentCalls: Int = 0
            private set
        private var inFlightCalls: Int = 0

        override suspend fun run(maxBatchSize: Int): FlushReport {
            mutex.withLock {
                inFlightCalls += 1
                maxConcurrentCalls = maxOf(maxConcurrentCalls, inFlightCalls)
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
            val coordinator =
                DefaultAutoFlushCoordinator(
                    flushQueuedScansUseCase = useCase,
                    mobileScanRepository = repo,
                    connectivityProvider = ConnectivityProvider { true },
                    clock = java.time.Clock.systemUTC(),
                    coordinatorDispatcher = StandardTestDispatcher(testScheduler)
                )

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
            val coordinator =
                DefaultAutoFlushCoordinator(
                    flushQueuedScansUseCase = useCase,
                    mobileScanRepository = repo,
                    connectivityProvider = ConnectivityProvider { true },
                    clock = java.time.Clock.systemUTC(),
                    coordinatorDispatcher = StandardTestDispatcher(testScheduler)
                )

            val jobs =
                (1..10).map {
                    async {
                        coordinator.requestFlush(AutoFlushTrigger.AfterEnqueue)
                    }
                }
            jobs.awaitAll()

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
            val coordinator =
                DefaultAutoFlushCoordinator(
                    flushQueuedScansUseCase = useCase,
                    mobileScanRepository = repo,
                    connectivityProvider = ConnectivityProvider { true },
                    clock = java.time.Clock.systemUTC(),
                    coordinatorDispatcher = StandardTestDispatcher(testScheduler)
                )

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
            val coordinator =
                DefaultAutoFlushCoordinator(
                    flushQueuedScansUseCase = useCase,
                    mobileScanRepository = repo,
                    connectivityProvider = ConnectivityProvider { true },
                    clock = java.time.Clock.systemUTC(),
                    coordinatorDispatcher = StandardTestDispatcher(testScheduler)
                )

            coordinator.requestFlush(AutoFlushTrigger.Manual)
            advanceUntilIdle()

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
            val coordinator =
                DefaultAutoFlushCoordinator(
                    flushQueuedScansUseCase = useCase,
                    mobileScanRepository = repo,
                    connectivityProvider = ConnectivityProvider { false },
                    clock = java.time.Clock.systemUTC(),
                    coordinatorDispatcher = StandardTestDispatcher(testScheduler)
                )

            coordinator.requestFlush(AutoFlushTrigger.AfterEnqueue)
            advanceUntilIdle()

            assertThat(useCase.reports).isEmpty()
        }

    @Test
    fun madeProgressWithRemainingDepthRunsSecondTime() =
        runTest(StandardTestDispatcher()) {
            var invocation = 0
            val repo =
                RecordingScanRepository().apply {
                    depth = 2
                }
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
                    clock = java.time.Clock.systemUTC(),
                    coordinatorDispatcher = StandardTestDispatcher(testScheduler)
                )

            coordinator.requestFlush(AutoFlushTrigger.Manual)

            advanceUntilIdle()

            assertThat(invocation).isEqualTo(2)
            assertThat(useCase.reports).hasSize(2)
            assertThat(useCase.maxConcurrentCalls).isEqualTo(1)
        }
}

