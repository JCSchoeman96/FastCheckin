package za.co.voelgoed.fastcheck.feature.queue

/**
 * Focused B1 projection tests for QueueViewModel.
 *
 * Verifies queue depth comes from repository-backed observation and that
 * transient upload/retry state comes from coordinator state only.
 */
import com.google.common.truth.Truth.assertThat
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Before
import org.junit.Test
import za.co.voelgoed.fastcheck.core.autoflush.AutoFlushCoordinator
import za.co.voelgoed.fastcheck.core.autoflush.AutoFlushCoordinatorState
import za.co.voelgoed.fastcheck.domain.model.FlushExecutionStatus
import za.co.voelgoed.fastcheck.domain.model.FlushReport
import za.co.voelgoed.fastcheck.domain.model.PendingScan
import za.co.voelgoed.fastcheck.domain.model.QueueCreationResult
import za.co.voelgoed.fastcheck.domain.usecase.QueueCapturedScanUseCase
import za.co.voelgoed.fastcheck.data.repository.MobileScanRepository

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

        fun emit(value: AutoFlushCoordinatorState) {
            _state.value = value
        }

        override fun requestFlush(trigger: za.co.voelgoed.fastcheck.core.autoflush.AutoFlushTrigger) = Unit
    }

    private class FakeQueueCapturedScanUseCase : QueueCapturedScanUseCase {
        override suspend fun enqueue(
            ticketCode: String,
            direction: za.co.voelgoed.fastcheck.domain.model.ScanDirection,
            operatorName: String,
            entranceName: String
        ): QueueCreationResult = QueueCreationResult.InvalidTicketCode
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
    }

    @Test
    fun queueDepthIsObserved_notManuallyRefreshed() = runTest(dispatcher) {
        val coordinator = FakeAutoFlushCoordinator()
        val repo = FakeMobileScanRepository()
        val viewModel =
            QueueViewModel(
                queueCapturedScanUseCase = FakeQueueCapturedScanUseCase(),
                autoFlushCoordinator = coordinator,
                mobileScanRepository = repo,
                queueUiStateFactory = QueueUiStateFactory()
            )

        repo.depthFlow.value = 7
        advanceUntilIdle()

        assertThat(viewModel.uiState.value.localQueueDepth).isEqualTo(7)
    }

    @Test
    fun uploadingWhileQueueExists_setsUploadingState() = runTest(dispatcher) {
        val coordinator = FakeAutoFlushCoordinator()
        val repo = FakeMobileScanRepository()
        val viewModel =
            QueueViewModel(
                queueCapturedScanUseCase = FakeQueueCapturedScanUseCase(),
                autoFlushCoordinator = coordinator,
                mobileScanRepository = repo,
                queueUiStateFactory = QueueUiStateFactory()
            )

        repo.depthFlow.value = 3
        coordinator.emit(AutoFlushCoordinatorState(isFlushing = true))
        advanceUntilIdle()

        assertThat(viewModel.uiState.value.localQueueDepth).isEqualTo(3)
        assertThat(viewModel.uiState.value.uploadStateLabel).isEqualTo("Uploading")
    }

    @Test
    fun retryPending_showsAttemptMetadata() = runTest(dispatcher) {
        val coordinator = FakeAutoFlushCoordinator()
        val repo = FakeMobileScanRepository()
        val viewModel =
            QueueViewModel(
                queueCapturedScanUseCase = FakeQueueCapturedScanUseCase(),
                autoFlushCoordinator = coordinator,
                mobileScanRepository = repo,
                queueUiStateFactory = QueueUiStateFactory()
            )

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
        val repo = FakeMobileScanRepository()
        val viewModel =
            QueueViewModel(
                queueCapturedScanUseCase = FakeQueueCapturedScanUseCase(),
                autoFlushCoordinator = coordinator,
                mobileScanRepository = repo,
                queueUiStateFactory = QueueUiStateFactory()
            )

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
}

