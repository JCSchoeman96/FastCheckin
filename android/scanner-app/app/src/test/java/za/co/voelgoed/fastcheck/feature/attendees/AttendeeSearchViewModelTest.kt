package za.co.voelgoed.fastcheck.feature.attendees

import com.google.common.truth.Truth.assertThat
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
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
import za.co.voelgoed.fastcheck.domain.model.AttendeeDetailRecord
import za.co.voelgoed.fastcheck.domain.model.AttendeeSearchRecord
import za.co.voelgoed.fastcheck.domain.model.PendingScan
import za.co.voelgoed.fastcheck.domain.model.QueueCreationResult
import za.co.voelgoed.fastcheck.domain.model.ScanDirection
import za.co.voelgoed.fastcheck.domain.usecase.QueueCapturedScanUseCase

@OptIn(ExperimentalCoroutinesApi::class)
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
    fun selectingAttendeeShowsDetailState() = runTest(dispatcher) {
        val viewModel =
            createViewModel(
                repository =
                    FakeAttendeeLookupRepository(
                        searchResults = listOf(searchRecord(id = 1, ticketCode = "VG-100")),
                        detailRecord = detailRecord(id = 1, ticketCode = "VG-100")
                    )
            )

        viewModel.setEventId(5)
        viewModel.updateQuery("VG-100")
        advanceUntilIdle()
        viewModel.selectAttendee(1)
        advanceUntilIdle()

        assertThat(viewModel.uiState.value.isShowingSelection).isTrue()
        assertThat(viewModel.uiState.value.selectedAttendee?.ticketCode).isEqualTo("VG-100")
        assertThat(viewModel.uiState.value.selectedAttendee?.attendanceLabel).isEqualTo("Checked in")
    }

    @Test
    fun updatingQueryClearsExistingSelection() = runTest(dispatcher) {
        val viewModel =
            createViewModel(
                repository =
                    FakeAttendeeLookupRepository(
                        searchResults = listOf(searchRecord(id = 1, ticketCode = "VG-100")),
                        detailRecord = detailRecord(id = 1, ticketCode = "VG-100")
                    )
            )

        viewModel.setEventId(5)
        viewModel.updateQuery("VG-100")
        advanceUntilIdle()
        viewModel.selectAttendee(1)
        advanceUntilIdle()
        viewModel.updateQuery("VG")
        advanceUntilIdle()

        assertThat(viewModel.uiState.value.selectedAttendee).isNull()
        assertThat(viewModel.uiState.value.isShowingSelection).isFalse()
    }

    @Test
    fun rebindingSameEventClearsPriorSessionStateAndTransientActionUi() = runTest(dispatcher) {
        val queueUseCase = FakeQueueCapturedScanUseCase(QueueCreationResult.ReplaySuppressed)
        val viewModel =
            createViewModel(
                repository =
                    FakeAttendeeLookupRepository(
                        searchResults = listOf(searchRecord(id = 1, ticketCode = "VG-100")),
                        detailRecord = detailRecord(id = 1, ticketCode = "VG-100")
                    ),
                queueCapturedScanUseCase = queueUseCase
            )

        viewModel.setEventId(5)
        viewModel.updateQuery("VG-100")
        advanceUntilIdle()
        viewModel.selectAttendee(1)
        advanceUntilIdle()
        viewModel.queueManualCheckIn()
        advanceUntilIdle()

        assertThat(viewModel.uiState.value.actionBanner?.title).isEqualTo("Already queued locally")

        viewModel.setEventId(5)
        advanceUntilIdle()

        assertThat(viewModel.uiState.value.query).isEmpty()
        assertThat(viewModel.uiState.value.selectedAttendee).isNull()
        assertThat(viewModel.uiState.value.actionBanner).isNull()
        assertThat(viewModel.uiState.value.isShowingSelection).isFalse()
        assertThat(viewModel.uiState.value.isSubmittingManualCheckIn).isFalse()
        assertThat(viewModel.uiState.value.emptyState).isEqualTo(SearchEmptyState.Prompt)
    }

    @Test
    fun manualCheckInSuccessRemainsQueuedLocalOnlyAndRequestsAutoFlush() = runTest(dispatcher) {
        val autoFlushCoordinator = RecordingAutoFlushCoordinator()
        val queueUseCase = FakeQueueCapturedScanUseCase(QueueCreationResult.Enqueued(pendingScan()))
        val viewModel =
            createViewModel(
                repository =
                    FakeAttendeeLookupRepository(
                        detailRecord = detailRecord(id = 1, ticketCode = "VG-100")
                    ),
                queueCapturedScanUseCase = queueUseCase,
                autoFlushCoordinator = autoFlushCoordinator
            )

        viewModel.setEventId(5)
        advanceUntilIdle()
        viewModel.selectAttendee(1)
        advanceUntilIdle()
        viewModel.queueManualCheckIn()
        advanceUntilIdle()

        assertThat(viewModel.uiState.value.actionBanner?.title).isEqualTo("Queued locally")
        assertThat(viewModel.uiState.value.actionBanner?.message)
            .contains("Server confirmation is still pending upload")
        assertThat(viewModel.uiState.value.actionBanner?.message)
            .doesNotContain("accepted by server")
        assertThat(queueUseCase.lastTicketCode).isEqualTo("VG-100")
        assertThat(queueUseCase.lastDirection).isEqualTo(ScanDirection.IN)
        assertThat(autoFlushCoordinator.requests).containsExactly(AutoFlushTrigger.AfterEnqueue)
    }

    @Test
    fun manualCheckInReplaySuppressedDoesNotRequestAutoFlush() = runTest(dispatcher) {
        val autoFlushCoordinator = RecordingAutoFlushCoordinator()
        val queueUseCase = FakeQueueCapturedScanUseCase(QueueCreationResult.ReplaySuppressed)
        val viewModel =
            createViewModel(
                repository =
                    FakeAttendeeLookupRepository(
                        detailRecord = detailRecord(id = 1, ticketCode = "VG-100")
                    ),
                queueCapturedScanUseCase = queueUseCase,
                autoFlushCoordinator = autoFlushCoordinator
            )

        viewModel.setEventId(5)
        advanceUntilIdle()
        viewModel.selectAttendee(1)
        advanceUntilIdle()
        viewModel.queueManualCheckIn()
        advanceUntilIdle()

        assertThat(viewModel.uiState.value.actionBanner?.title).isEqualTo("Already queued locally")
        assertThat(viewModel.uiState.value.actionBanner?.message).contains("No new upload was queued")
        assertThat(autoFlushCoordinator.requests).isEmpty()
    }

    @Test
    fun manualCheckInFailureClearsSubmittingStateAndAllowsRetry() = runTest(dispatcher) {
        val autoFlushCoordinator = RecordingAutoFlushCoordinator()
        val queueUseCase = ThrowingQueueCapturedScanUseCase(IllegalStateException("storage failed"))
        val viewModel =
            createViewModel(
                repository =
                    FakeAttendeeLookupRepository(
                        detailRecord = detailRecord(id = 1, ticketCode = "VG-100")
                    ),
                queueCapturedScanUseCase = queueUseCase,
                autoFlushCoordinator = autoFlushCoordinator
            )

        viewModel.setEventId(5)
        advanceUntilIdle()
        viewModel.selectAttendee(1)
        advanceUntilIdle()

        viewModel.queueManualCheckIn()
        advanceUntilIdle()

        assertThat(viewModel.uiState.value.isSubmittingManualCheckIn).isFalse()
        assertThat(viewModel.uiState.value.actionBanner?.title).isEqualTo("Could not queue locally")
        assertThat(viewModel.uiState.value.actionBanner?.message)
            .isEqualTo("Manual check-in could not be queued locally. Try again.")
        assertThat(autoFlushCoordinator.requests).isEmpty()

        viewModel.queueManualCheckIn()
        advanceUntilIdle()

        assertThat(queueUseCase.enqueueCallCount).isEqualTo(2)
        assertThat(viewModel.uiState.value.isSubmittingManualCheckIn).isFalse()
    }

    private fun createViewModel(
        repository: FakeAttendeeLookupRepository = FakeAttendeeLookupRepository(),
        queueCapturedScanUseCase: QueueCapturedScanUseCase =
            FakeQueueCapturedScanUseCase(QueueCreationResult.InvalidTicketCode),
        autoFlushCoordinator: RecordingAutoFlushCoordinator = RecordingAutoFlushCoordinator()
    ): AttendeeSearchViewModel =
        AttendeeSearchViewModel(
            attendeeLookupRepository = repository,
            queueCapturedScanUseCase = queueCapturedScanUseCase,
            autoFlushCoordinator = autoFlushCoordinator
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
        var lastDirection: ScanDirection? = null

        override suspend fun enqueue(
            ticketCode: String,
            direction: ScanDirection,
            operatorName: String,
            entranceName: String
        ): QueueCreationResult {
            lastTicketCode = ticketCode
            lastDirection = direction
            return result
        }
    }

    private class ThrowingQueueCapturedScanUseCase(
        private val throwable: Throwable
    ) : QueueCapturedScanUseCase {
        var enqueueCallCount: Int = 0

        override suspend fun enqueue(
            ticketCode: String,
            direction: ScanDirection,
            operatorName: String,
            entranceName: String
        ): QueueCreationResult {
            enqueueCallCount += 1
            throw throwable
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
        ticketCode: String,
        checkedOutAt: String? = null,
        isCurrentlyInside: Boolean = false
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
            isCurrentlyInside = isCurrentlyInside,
            checkedInAt = "2026-03-28T09:00:00Z",
            checkedOutAt = checkedOutAt,
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
            entranceName = "Attendee Search",
            operatorName = "Attendee Search"
        )
}
