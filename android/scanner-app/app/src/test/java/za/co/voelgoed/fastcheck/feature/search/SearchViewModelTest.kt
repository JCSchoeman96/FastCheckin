package za.co.voelgoed.fastcheck.feature.search

import com.google.common.truth.Truth.assertThat
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.UnconfinedTestDispatcher
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
import za.co.voelgoed.fastcheck.domain.model.LocalAdmissionDecision
import za.co.voelgoed.fastcheck.domain.model.ScanDirection
import za.co.voelgoed.fastcheck.domain.usecase.AdmitScanUseCase
import za.co.voelgoed.fastcheck.feature.search.detail.model.ManualActionUiState

@OptIn(ExperimentalCoroutinesApi::class)
class SearchViewModelTest {
    private val mainDispatcher = UnconfinedTestDispatcher()

    @Before
    fun setUp() {
        Dispatchers.setMain(mainDispatcher)
    }

    @After
    fun tearDown() {
        Dispatchers.resetMain()
    }

    private val sampleDetail =
        AttendeeDetailRecord(
            id = 1L,
            eventId = 5L,
            ticketCode = "VG-1",
            firstName = "A",
            lastName = "B",
            displayName = "A B",
            email = "a@b.com",
            ticketType = "G",
            paymentStatus = "completed",
            isCurrentlyInside = false,
            checkedInAt = null,
            checkedOutAt = null,
            allowedCheckins = 1,
            checkinsRemaining = 1,
            updatedAt = "2026-04-06T10:00:00Z",
            localOverlayState = null,
            localConflictReasonCode = null,
            localConflictMessage = null,
            localOverlayScannedAt = null,
            expectedRemainingAfterOverlay = null
        )

    private class FakeAutoFlushCoordinator : AutoFlushCoordinator {
        private val _state = MutableStateFlow(AutoFlushCoordinatorState())
        override val state: kotlinx.coroutines.flow.StateFlow<AutoFlushCoordinatorState> = _state
        var lastTrigger: AutoFlushTrigger? = null

        override fun requestFlush(trigger: AutoFlushTrigger) {
            lastTrigger = trigger
        }
    }

    private class FakeAttendeeLookupRepository(
        private val detail: AttendeeDetailRecord
    ) : AttendeeLookupRepository {
        override fun search(eventId: Long, query: String): Flow<List<AttendeeSearchRecord>> = flowOf(emptyList())

        override fun observeDetail(eventId: Long, attendeeId: Long): Flow<AttendeeDetailRecord?> =
            if (eventId == detail.eventId && attendeeId == detail.id) {
                flowOf(detail)
            } else {
                flowOf(null)
            }

        override suspend fun findByTicketCode(eventId: Long, ticketCode: String): AttendeeDetailRecord? = null
    }

    private class FakeAdmitScanUseCase(
        var decision: LocalAdmissionDecision =
            LocalAdmissionDecision.Accepted(
                attendeeId = 1L,
                displayName = "A B",
                ticketCode = "VG-1",
                idempotencyKey = "k",
                scannedAt = "2026-04-06T10:00:00Z",
                localQueueId = 1L
            )
    ) : AdmitScanUseCase {
        override suspend fun admit(
            ticketCode: String,
            direction: ScanDirection,
            operatorName: String,
            entranceName: String
        ): LocalAdmissionDecision = decision
    }

    @Test
    fun sameObservedSessionDoesNotResetQueryOrSelection() = runTest {
        val vm = SearchViewModel(FakeAttendeeLookupRepository(sampleDetail), FakeAdmitScanUseCase(), FakeAutoFlushCoordinator())
        backgroundScope.launch {
            vm.selectedDetail.collect { }
            vm.results.collect { }
        }
        vm.observeSession(5L, 1000L)
        vm.onQueryChanged("find-me")
        vm.selectAttendee(1L)
        advanceUntilIdle()

        vm.observeSession(5L, 1000L)
        advanceUntilIdle()

        assertThat(vm.queryState.value).isEqualTo("find-me")
        assertThat(vm.selectedDetail.value).isNotNull()
    }

    @Test
    fun differentAuthenticatedSessionResetsQuerySelectionAndManualAction() = runTest {
        val vm = SearchViewModel(FakeAttendeeLookupRepository(sampleDetail), FakeAdmitScanUseCase(), FakeAutoFlushCoordinator())
        vm.observeSession(5L, 1000L)
        advanceUntilIdle()
        vm.onQueryChanged("x")
        advanceUntilIdle()
        vm.selectAttendee(1L)
        advanceUntilIdle()

        vm.observeSession(5L, 2000L)
        advanceUntilIdle()

        assertThat(vm.queryState.value).isEmpty()
        assertThat(vm.selectedDetail.value).isNull()
        assertThat(vm.manualActionUiState.value).isEqualTo(ManualActionUiState())
    }

    @Test
    fun clearSearchWipesQuerySelectionAndManualAction() = runTest {
        val vm = SearchViewModel(FakeAttendeeLookupRepository(sampleDetail), FakeAdmitScanUseCase(), FakeAutoFlushCoordinator())
        vm.observeSession(5L, 1000L)
        advanceUntilIdle()
        vm.onQueryChanged("y")
        advanceUntilIdle()
        vm.selectAttendee(1L)
        advanceUntilIdle()

        vm.clearSearch()
        advanceUntilIdle()

        assertThat(vm.queryState.value).isEmpty()
        assertThat(vm.selectedDetail.value).isNull()
        assertThat(vm.manualActionUiState.value).isEqualTo(ManualActionUiState())
    }

    @Test
    fun manualAdmitAcceptedRequestsAutoflush() = runTest {
        val flush = FakeAutoFlushCoordinator()
        val vm = SearchViewModel(FakeAttendeeLookupRepository(sampleDetail), FakeAdmitScanUseCase(), flush)
        backgroundScope.launch {
            vm.selectedDetail.collect { }
            vm.results.collect { }
        }
        vm.observeSession(5L, 1000L)
        vm.selectAttendee(1L)
        advanceUntilIdle()

        vm.admitSelectedAttendee()
        advanceUntilIdle()

        assertThat(flush.lastTrigger).isEqualTo(AutoFlushTrigger.AfterEnqueue)
    }

    @Test
    fun manualAdmitRejectedDoesNotRequestAutoflush() = runTest {
        val flush = FakeAutoFlushCoordinator()
        val admit =
            FakeAdmitScanUseCase(
                decision =
                    LocalAdmissionDecision.Rejected(
                        reason = za.co.voelgoed.fastcheck.domain.model.LocalAdmissionRejectReason.AlreadyInside,
                        displayMessage = "inside",
                        ticketCode = "VG-1"
                    )
            )
        val vm = SearchViewModel(FakeAttendeeLookupRepository(sampleDetail), admit, flush)
        vm.observeSession(5L, 1000L)
        advanceUntilIdle()
        vm.selectAttendee(1L)
        advanceUntilIdle()

        vm.admitSelectedAttendee()
        advanceUntilIdle()

        assertThat(flush.lastTrigger).isNull()
    }

    @Test
    fun manualAdmitReviewRequiredDoesNotRequestAutoflush() = runTest {
        val flush = FakeAutoFlushCoordinator()
        val admit =
            FakeAdmitScanUseCase(
                decision =
                    LocalAdmissionDecision.ReviewRequired(
                        reason = za.co.voelgoed.fastcheck.domain.model.LocalAdmissionReviewReason.CacheNotTrusted,
                        displayMessage = "review",
                        ticketCode = "VG-1"
                    )
            )
        val vm = SearchViewModel(FakeAttendeeLookupRepository(sampleDetail), admit, flush)
        vm.observeSession(5L, 1000L)
        advanceUntilIdle()
        vm.selectAttendee(1L)
        advanceUntilIdle()

        vm.admitSelectedAttendee()
        advanceUntilIdle()

        assertThat(flush.lastTrigger).isNull()
    }
}
