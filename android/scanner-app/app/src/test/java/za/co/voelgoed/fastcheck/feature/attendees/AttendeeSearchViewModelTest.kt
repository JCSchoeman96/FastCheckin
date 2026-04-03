package za.co.voelgoed.fastcheck.feature.attendees

import com.google.common.truth.Truth.assertThat
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.flowOf
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
import za.co.voelgoed.fastcheck.data.repository.AttendeeLookupRepository
import za.co.voelgoed.fastcheck.data.repository.MobileScanRepository
import za.co.voelgoed.fastcheck.domain.model.AttendeeDetailRecord
import za.co.voelgoed.fastcheck.domain.model.AttendeeSearchRecord
import za.co.voelgoed.fastcheck.domain.model.FlushExecutionStatus
import za.co.voelgoed.fastcheck.domain.model.FlushItemOutcome
import za.co.voelgoed.fastcheck.domain.model.FlushItemResult
import za.co.voelgoed.fastcheck.domain.model.FlushReport
import za.co.voelgoed.fastcheck.domain.model.PendingScan
import za.co.voelgoed.fastcheck.domain.model.QueueCreationResult
import za.co.voelgoed.fastcheck.domain.model.ScanDirection
import za.co.voelgoed.fastcheck.domain.usecase.QueueCapturedScanUseCase

class AttendeeSearchViewModelTest {
    private val dispatcher = StandardTestDispatcher()

    @Before
    fun setUp() {
        Dispatchers.setMain(dispatcher)
    }

    @After
    fun tearDown() {
        Dispatchers.resetMain()
    }

    @Test
    fun blankQueryShowsPromptAndNoResults() = runTest(dispatcher) {
        val viewModel =
            createViewModel(
                repository =
                    FakeAttendeeLookupRepository(
                        searchResults = listOf(searchRecord(id = 1, ticketCode = "VG-001"))
                    )
            )

        viewModel.setEventId(5)
        advanceUntilIdle()

        assertThat(viewModel.uiState.value.emptyState).isEqualTo(SearchEmptyState.Prompt)
        assertThat(viewModel.uiState.value.results).isEmpty()
    }

    @Test
    fun queryUpdatesLoadResultsDeterministically() = runTest(dispatcher) {
        val viewModel =
            createViewModel(
                repository =
                    FakeAttendeeLookupRepository(
                        searchResults =
                            listOf(
                                searchRecord(id = 2, ticketCode = "VG-101"),
                                searchRecord(id = 1, ticketCode = "VG-100")
                            )
                    )
            )

        viewModel.setEventId(5)
        viewModel.updateQuery("VG-10")
        advanceUntilIdle()

        assertThat(viewModel.uiState.value.results.map { it.id }).containsExactly(2L, 1L).inOrder()
        assertThat(viewModel.uiState.value.emptyState).isEqualTo(SearchEmptyState.Hidden)
    }

    @Test
    fun selectingAttendeeShowsDetailAndLatestFlushContextOnly() = runTest(dispatcher) {
        val flushReport =
            FlushReport(
                executionStatus = FlushExecutionStatus.COMPLETED,
                itemOutcomes =
                    listOf(
                        FlushItemResult(
                            idempotencyKey = "idem-1",
                            ticketCode = "VG-100",
                            outcome = FlushItemOutcome.SUCCESS,
                            message = "Check-in successful"
                        )
                    )
            )
        val viewModel =
            createViewModel(
                repository =
                    FakeAttendeeLookupRepository(
                        searchResults = listOf(searchRecord(id = 1, ticketCode = "VG-100")),
                        detailRecord = detailRecord(id = 1, ticketCode = "VG-100")
                    ),
                mobileScanRepository = FakeMobileScanRepository(flushReport = flushReport)
            )

        viewModel.setEventId(5)
        viewModel.updateQuery("VG-100")
        advanceUntilIdle()
        viewModel.selectAttendee(1)
        advanceUntilIdle()

        assertThat(viewModel.uiState.value.selectedAttendee?.ticketCode).isEqualTo("VG-100")
        assertThat(viewModel.uiState.value.recentUploadBanner?.title)
            .isEqualTo("Latest flush outcome for this ticket")
    }

    @Test
    fun manualCheckInSuccessRemainsQueuedLocalOnlyAndRequestsAutoFlush() = runTest(dispatcher) {
        val autoFlushCoordinator = RecordingAutoFlushCoordinator()
        val useCase = FakeQueueCapturedScanUseCase(QueueCreationResult.Enqueued(pendingScan()))
        val viewModel =
            createViewModel(
                repository =
                    FakeAttendeeLookupRepository(
                        detailRecord = detailRecord(id = 1, ticketCode = "VG-100")
                    ),
                queueCapturedScanUseCase = useCase,
                autoFlushCoordinator = autoFlushCoordinator
            )

        viewModel.setEventId(5)
        advanceUntilIdle()
        viewModel.selectAttendee(1)
        advanceUntilIdle()
        viewModel.queueManualCheckIn()
        advanceUntilIdle()

        assertThat(viewModel.uiState.value.actionBanner?.title).isEqualTo("Queued locally")
        assertThat(viewModel.uiState.value.actionBanner?.message).contains("pending upload")
        assertThat(viewModel.uiState.value.actionBanner?.message).doesNotContain("accepted by server")
        assertThat(autoFlushCoordinator.requests).containsExactly(AutoFlushTrigger.AfterEnqueue)
        assertThat(useCase.lastTicketCode).isEqualTo("VG-100")
    }

    private fun createViewModel(
        repository: FakeAttendeeLookupRepository = FakeAttendeeLookupRepository(),
        queueCapturedScanUseCase: FakeQueueCapturedScanUseCase = FakeQueueCapturedScanUseCase(QueueCreationResult.InvalidTicketCode),
        autoFlushCoordinator: RecordingAutoFlushCoordinator = RecordingAutoFlushCoordinator(),
        mobileScanRepository: FakeMobileScanRepository = FakeMobileScanRepository()
    ): AttendeeSearchViewModel =
        AttendeeSearchViewModel(
            attendeeLookupRepository = repository,
            queueCapturedScanUseCase = queueCapturedScanUseCase,
            autoFlushCoordinator = autoFlushCoordinator,
            mobileScanRepository = mobileScanRepository
        )

    private class FakeAttendeeLookupRepository(
        private val searchResults: List<AttendeeSearchRecord> = emptyList(),
        private val detailRecord: AttendeeDetailRecord? = null
    ) : AttendeeLookupRepository {
        override fun search(eventId: Long, query: String): Flow<List<AttendeeSearchRecord>> =
            if (query.isBlank()) {
                flowOf(emptyList())
            } else {
                flowOf(searchResults)
            }

        override fun observeDetail(eventId: Long, attendeeId: Long): Flow<AttendeeDetailRecord?> =
            flowOf(detailRecord?.takeIf { it.id == attendeeId })
    }

    private class FakeQueueCapturedScanUseCase(
        private val result: QueueCreationResult
    ) : QueueCapturedScanUseCase {
        var lastTicketCode: String? = null

        override suspend fun enqueue(
            ticketCode: String,
            direction: ScanDirection,
            operatorName: String,
            entranceName: String
        ): QueueCreationResult {
            lastTicketCode = ticketCode
            return result
        }
    }

    private class RecordingAutoFlushCoordinator : AutoFlushCoordinator {
        override val state: MutableStateFlow<AutoFlushCoordinatorState> =
            MutableStateFlow(AutoFlushCoordinatorState())

        val requests = mutableListOf<AutoFlushTrigger>()

        override fun requestFlush(trigger: AutoFlushTrigger) {
            requests += trigger
        }
    }

    private class FakeMobileScanRepository(
        flushReport: FlushReport? = null
    ) : MobileScanRepository {
        private val latestFlushReport = MutableStateFlow(flushReport)

        override suspend fun queueScan(scan: PendingScan): QueueCreationResult =
            QueueCreationResult.Enqueued(scan)

        override suspend fun flushQueuedScans(maxBatchSize: Int): FlushReport =
            FlushReport(executionStatus = FlushExecutionStatus.COMPLETED)

        override suspend fun pendingQueueDepth(): Int = 0

        override suspend fun latestFlushReport(): FlushReport? = latestFlushReport.value

        override fun observePendingQueueDepth(): Flow<Int> = flowOf(0)

        override fun observeLatestFlushReport(): Flow<FlushReport?> = latestFlushReport
    }

    private fun searchRecord(
        id: Long,
        ticketCode: String
    ): AttendeeSearchRecord =
        AttendeeSearchRecord(
            id = id,
            eventId = 5,
            ticketCode = ticketCode,
            displayName = "Attendee $id",
            email = "attendee$id@example.com",
            ticketType = "VIP",
            paymentStatus = "completed",
            isCurrentlyInside = false,
            allowedCheckins = 2,
            checkinsRemaining = 1
        )

    private fun detailRecord(
        id: Long,
        ticketCode: String
    ): AttendeeDetailRecord =
        AttendeeDetailRecord(
            id = id,
            eventId = 5,
            ticketCode = ticketCode,
            firstName = "Attendee",
            lastName = "$id",
            displayName = "Attendee $id",
            email = "attendee$id@example.com",
            ticketType = "VIP",
            paymentStatus = "completed",
            isCurrentlyInside = false,
            checkedInAt = "2026-03-28T09:00:00Z",
            checkedOutAt = null,
            allowedCheckins = 2,
            checkinsRemaining = 1,
            updatedAt = "2026-03-28T10:00:00Z"
        )

    private fun pendingScan(): PendingScan =
        PendingScan(
            localId = 1L,
            eventId = 5,
            ticketCode = "VG-100",
            idempotencyKey = "idem-1",
            createdAt = 1L,
            scannedAt = "2026-03-28T10:00:00Z",
            direction = ScanDirection.IN,
            entranceName = AttendeeSearchActionDefaults.entranceName,
            operatorName = AttendeeSearchActionDefaults.fallbackOperatorName
        )
}
