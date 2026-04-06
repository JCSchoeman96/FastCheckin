package za.co.voelgoed.fastcheck.feature.queue

import com.google.common.truth.Truth.assertThat
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Before
import org.junit.Test
import za.co.voelgoed.fastcheck.core.autoflush.AutoFlushCoordinator
import za.co.voelgoed.fastcheck.core.autoflush.AutoFlushCoordinatorState
import za.co.voelgoed.fastcheck.core.autoflush.AutoFlushTrigger
import za.co.voelgoed.fastcheck.core.connectivity.ConnectivityMonitor
import za.co.voelgoed.fastcheck.data.repository.MobileScanRepository
import za.co.voelgoed.fastcheck.domain.model.FlushExecutionStatus
import za.co.voelgoed.fastcheck.domain.model.FlushItemOutcome
import za.co.voelgoed.fastcheck.domain.model.FlushItemResult
import za.co.voelgoed.fastcheck.domain.model.FlushReport
import za.co.voelgoed.fastcheck.domain.model.PendingScan
import za.co.voelgoed.fastcheck.domain.model.QueueCreationResult
import za.co.voelgoed.fastcheck.domain.model.QuarantineSummary
import za.co.voelgoed.fastcheck.domain.model.ScanDirection
import za.co.voelgoed.fastcheck.domain.usecase.QueueCapturedScanUseCase

@OptIn(ExperimentalCoroutinesApi::class)
class QueueViewModelTest {
    private val dispatcher = StandardTestDispatcher()

    @Before
    fun setUp() {
        Dispatchers.setMain(dispatcher)
    }

    @After
    fun tearDown() {
        Dispatchers.resetMain()
    }

    private class FakeAutoFlushCoordinator : AutoFlushCoordinator {
        private val _state = MutableStateFlow(AutoFlushCoordinatorState())
        override val state: StateFlow<AutoFlushCoordinatorState> = _state
        var lastTrigger: AutoFlushTrigger? = null

        fun emit(value: AutoFlushCoordinatorState) {
            _state.value = value
        }

        override fun requestFlush(trigger: AutoFlushTrigger) {
            lastTrigger = trigger
        }
    }

    private class FakeConnectivityMonitor : ConnectivityMonitor {
        private val _isOnline = MutableStateFlow(true)
        override val isOnline: StateFlow<Boolean> = _isOnline

        fun emit(value: Boolean) {
            _isOnline.value = value
        }
    }

    private class FakeQueueCapturedScanUseCase : QueueCapturedScanUseCase {
        var result: QueueCreationResult = QueueCreationResult.InvalidTicketCode

        override suspend fun enqueue(
            ticketCode: String,
            direction: ScanDirection,
            operatorName: String,
            entranceName: String
        ): QueueCreationResult = result
    }

    private class FakeMobileScanRepository : MobileScanRepository {
        val depthFlow = MutableStateFlow(0)
        val reportFlow = MutableStateFlow<FlushReport?>(null)

        override suspend fun queueScan(scan: PendingScan): QueueCreationResult {
            throw UnsupportedOperationException()
        }

        override suspend fun flushQueuedScans(maxBatchSize: Int): FlushReport {
            throw UnsupportedOperationException()
        }

        override suspend fun pendingQueueDepth(): Int = depthFlow.value

        override suspend fun latestFlushReport(): FlushReport? = reportFlow.value

        override fun observePendingQueueDepth(): Flow<Int> = depthFlow

        override fun observeLatestFlushReport(): Flow<FlushReport?> = reportFlow

        override suspend fun quarantineCount(): Int = 0

        override suspend fun latestQuarantineSummary(): QuarantineSummary? = null

        override fun observeQuarantineCount(): Flow<Int> = flowOf(0)

        override fun observeLatestQuarantineSummary(): Flow<QuarantineSummary?> = flowOf(null)
    }

    @Test
    fun queueDepthIsObserved_notManuallyRefreshed() = runTest(dispatcher) {
        val coordinator = FakeAutoFlushCoordinator()
        val connectivityMonitor = FakeConnectivityMonitor()
        val repo = FakeMobileScanRepository()
        val viewModel = createViewModel(coordinator, connectivityMonitor, repo, FakeQueueCapturedScanUseCase())

        repo.depthFlow.value = 7
        advanceUntilIdle()

        assertThat(viewModel.uiState.value.localQueueDepth).isEqualTo(7)
    }

    @Test
    fun offlineConnectivityWinsOverPersistedFlushTruth() = runTest(dispatcher) {
        val coordinator = FakeAutoFlushCoordinator()
        val connectivityMonitor = FakeConnectivityMonitor()
        val repo = FakeMobileScanRepository()
        val viewModel = createViewModel(coordinator, connectivityMonitor, repo, FakeQueueCapturedScanUseCase())

        repo.reportFlow.value =
            FlushReport(
                executionStatus = FlushExecutionStatus.AUTH_EXPIRED,
                authExpired = true,
                summaryMessage = "Persisted auth expired"
            )
        connectivityMonitor.emit(false)
        advanceUntilIdle()

        assertThat(viewModel.uiState.value.uploadStateLabel).isEqualTo("Offline")
    }

    @Test
    fun persistedLatestFlushReportDrivesQueueHint_evenWhenCoordinatorHasNoLastFlushReport() =
        runTest(dispatcher) {
            val coordinator = FakeAutoFlushCoordinator()
            val connectivityMonitor = FakeConnectivityMonitor()
            val repo = FakeMobileScanRepository()
            val viewModel =
                createViewModel(coordinator, connectivityMonitor, repo, FakeQueueCapturedScanUseCase())

            repo.reportFlow.value =
                FlushReport(
                    executionStatus = FlushExecutionStatus.COMPLETED,
                    itemOutcomes =
                        listOf(
                            FlushItemResult(
                                idempotencyKey = "idem-1",
                                ticketCode = "VG-1",
                                outcome = FlushItemOutcome.DUPLICATE,
                                message = "Already processed"
                            )
                        ),
                    uploadedCount = 1
                )
            advanceUntilIdle()

            assertThat(viewModel.uiState.value.serverResultHint).isEqualTo("Already processed by server: 1")
        }

    @Test
    fun recreatedViewModelRestoresHintFromRepository_evenWhenCoordinatorReportIsNullOrStale() =
        runTest(dispatcher) {
            val repo = FakeMobileScanRepository()
            repo.reportFlow.value =
                FlushReport(
                    executionStatus = FlushExecutionStatus.COMPLETED,
                    itemOutcomes =
                        listOf(
                            FlushItemResult(
                                idempotencyKey = "idem-1",
                                ticketCode = "VG-1",
                                outcome = FlushItemOutcome.TERMINAL_ERROR,
                                message = "Payment issue",
                                reasonCode = "payment_invalid"
                            )
                        ),
                    uploadedCount = 1
                )

            val firstCoordinator = FakeAutoFlushCoordinator()
            val firstConnectivityMonitor = FakeConnectivityMonitor()
            val firstViewModel =
                createViewModel(
                    firstCoordinator,
                    firstConnectivityMonitor,
                    repo,
                    FakeQueueCapturedScanUseCase()
                )
            advanceUntilIdle()

            val secondCoordinator = FakeAutoFlushCoordinator()
            secondCoordinator.emit(
                AutoFlushCoordinatorState(
                    lastFlushReport =
                        FlushReport(
                            executionStatus = FlushExecutionStatus.AUTH_EXPIRED,
                            authExpired = true,
                            summaryMessage = "stale"
                        )
                )
            )
            val recreatedViewModel =
                createViewModel(
                    secondCoordinator,
                    FakeConnectivityMonitor(),
                    repo,
                    FakeQueueCapturedScanUseCase()
                )
            advanceUntilIdle()

            assertThat(firstViewModel.uiState.value.serverResultHint).isEqualTo("Payment invalid: 1")
            assertThat(recreatedViewModel.uiState.value.serverResultHint).isEqualTo("Payment invalid: 1")
        }

    @Test
    fun queueHintStaysNeutralWhenNoPersistedFlushTruthExists() = runTest(dispatcher) {
        val coordinator = FakeAutoFlushCoordinator()
        val connectivityMonitor = FakeConnectivityMonitor()
        val repo = FakeMobileScanRepository()
        val viewModel = createViewModel(coordinator, connectivityMonitor, repo, FakeQueueCapturedScanUseCase())

        repo.depthFlow.value = 4
        advanceUntilIdle()

        assertThat(viewModel.uiState.value.serverResultHint).isEqualTo("No server outcomes yet.")
    }

    @Test
    fun uploadingWhileQueueExists_setsUploadingState() = runTest(dispatcher) {
        val coordinator = FakeAutoFlushCoordinator()
        val connectivityMonitor = FakeConnectivityMonitor()
        val repo = FakeMobileScanRepository()
        val viewModel = createViewModel(coordinator, connectivityMonitor, repo, FakeQueueCapturedScanUseCase())

        repo.depthFlow.value = 3
        coordinator.emit(AutoFlushCoordinatorState(isFlushing = true))
        advanceUntilIdle()

        assertThat(viewModel.uiState.value.localQueueDepth).isEqualTo(3)
        assertThat(viewModel.uiState.value.uploadStateLabel).isEqualTo("Uploading")
    }

    @Test
    fun retryPending_showsAttemptMetadata() = runTest(dispatcher) {
        val coordinator = FakeAutoFlushCoordinator()
        val connectivityMonitor = FakeConnectivityMonitor()
        val repo = FakeMobileScanRepository()
        val viewModel = createViewModel(coordinator, connectivityMonitor, repo, FakeQueueCapturedScanUseCase())

        coordinator.emit(
            AutoFlushCoordinatorState(
                isRetryScheduled = true,
                retryAttempt = 2,
                nextRetryAtEpochMs = 1_777_777_777_777
            )
        )
        advanceUntilIdle()

        assertThat(viewModel.uiState.value.uploadStateLabel).contains("attempt 2")
    }

    @Test
    fun authExpired_reflectedInUploadState() = runTest(dispatcher) {
        val coordinator = FakeAutoFlushCoordinator()
        val connectivityMonitor = FakeConnectivityMonitor()
        val repo = FakeMobileScanRepository()
        val viewModel = createViewModel(coordinator, connectivityMonitor, repo, FakeQueueCapturedScanUseCase())

        coordinator.emit(
            AutoFlushCoordinatorState(
                lastFlushReport =
                    FlushReport(
                        executionStatus = FlushExecutionStatus.AUTH_EXPIRED,
                        authExpired = true,
                        summaryMessage = "Auth expired"
                    )
            )
        )
        advanceUntilIdle()

        assertThat(viewModel.uiState.value.uploadStateLabel).isEqualTo("Auth expired")
    }

    @Test
    fun manualQueueingSuccessMessageRemainsLocalOnly() = runTest(dispatcher) {
        val coordinator = FakeAutoFlushCoordinator()
        val connectivityMonitor = FakeConnectivityMonitor()
        val repo = FakeMobileScanRepository()
        val useCase = FakeQueueCapturedScanUseCase()
        useCase.result =
            QueueCreationResult.Enqueued(
                PendingScan(
                    eventId = 5,
                    ticketCode = "VG-LOCAL",
                    idempotencyKey = "idem-local",
                    createdAt = 1_773_487_800_000,
                    scannedAt = "2026-03-13T08:30:00Z",
                    direction = ScanDirection.IN,
                    entranceName = "Manual Debug",
                    operatorName = "Operator"
                )
            )
        val viewModel = createViewModel(coordinator, connectivityMonitor, repo, useCase)

        viewModel.updateTicketCode("VG-LOCAL")
        viewModel.queueManualScan()
        advanceUntilIdle()

        assertThat(viewModel.uiState.value.lastActionMessage).isEqualTo("Queued VG-LOCAL for upload.")
        assertThat(viewModel.uiState.value.lastActionMessage).doesNotContain("Confirmed")
        assertThat(viewModel.uiState.value.lastActionMessage).doesNotContain("accepted by server")
        assertThat(coordinator.lastTrigger).isEqualTo(AutoFlushTrigger.AfterEnqueue)
    }

    private fun createViewModel(
        coordinator: FakeAutoFlushCoordinator,
        connectivityMonitor: FakeConnectivityMonitor,
        repo: FakeMobileScanRepository,
        useCase: FakeQueueCapturedScanUseCase
    ): QueueViewModel =
        QueueViewModel(
            queueCapturedScanUseCase = useCase,
            autoFlushCoordinator = coordinator,
            connectivityMonitor = connectivityMonitor,
            mobileScanRepository = repo,
            queueUiStateFactory = QueueUiStateFactory()
        )
}
