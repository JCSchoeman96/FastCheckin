package za.co.voelgoed.fastcheck.feature.attendees

import com.google.common.truth.Truth.assertThat
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Before
import org.junit.Test
import za.co.voelgoed.fastcheck.data.repository.AttendeeLookupRepository
import za.co.voelgoed.fastcheck.domain.model.AttendeeDetailRecord
import za.co.voelgoed.fastcheck.domain.model.AttendeeSearchRecord

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
    fun selectingAttendeeShowsSelectionStateOnly() = runTest(dispatcher) {
        val viewModel =
            createViewModel(
                repository =
                    FakeAttendeeLookupRepository(
                        searchResults = listOf(searchRecord(id = 1, ticketCode = "VG-100"))
                    )
            )

        viewModel.setEventId(5)
        viewModel.updateQuery("VG-100")
        advanceUntilIdle()
        viewModel.selectAttendee(1)
        advanceUntilIdle()

        assertThat(viewModel.uiState.value.selectedResult?.ticketCode).isEqualTo("VG-100")
        assertThat(viewModel.uiState.value.emptyState).isEqualTo(SearchEmptyState.Hidden)
    }

    @Test
    fun updatingQueryClearsExistingSelection() = runTest(dispatcher) {
        val viewModel =
            createViewModel(
                repository =
                    FakeAttendeeLookupRepository(
                        searchResults = listOf(searchRecord(id = 1, ticketCode = "VG-100"))
                    )
            )

        viewModel.setEventId(5)
        viewModel.updateQuery("VG-100")
        advanceUntilIdle()
        viewModel.selectAttendee(1)
        advanceUntilIdle()
        viewModel.updateQuery("VG")
        advanceUntilIdle()

        assertThat(viewModel.uiState.value.selectedResult).isNull()
    }

    private fun createViewModel(
        repository: FakeAttendeeLookupRepository = FakeAttendeeLookupRepository()
    ): AttendeeSearchViewModel =
        AttendeeSearchViewModel(attendeeLookupRepository = repository)

    private class FakeAttendeeLookupRepository(
        private val searchResults: List<AttendeeSearchRecord> = emptyList()
    ) : AttendeeLookupRepository {
        override fun search(eventId: Long, query: String): Flow<List<AttendeeSearchRecord>> =
            if (query.isBlank()) {
                flowOf(emptyList())
            } else {
                flowOf(searchResults)
            }

        override fun observeDetail(eventId: Long, attendeeId: Long): Flow<AttendeeDetailRecord?> =
            flowOf(null)
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
}
