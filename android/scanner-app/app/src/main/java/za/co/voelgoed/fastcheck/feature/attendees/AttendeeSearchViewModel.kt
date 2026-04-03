package za.co.voelgoed.fastcheck.feature.attendees

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import javax.inject.Inject
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.update
import za.co.voelgoed.fastcheck.core.designsystem.semantic.StatusTone
import za.co.voelgoed.fastcheck.core.designsystem.semantic.toPaymentUiState
import za.co.voelgoed.fastcheck.data.repository.AttendeeLookupRepository
import za.co.voelgoed.fastcheck.domain.model.AttendeeSearchRecord

@HiltViewModel
@OptIn(ExperimentalCoroutinesApi::class)
class AttendeeSearchViewModel @Inject constructor(
    private val attendeeLookupRepository: AttendeeLookupRepository
) : ViewModel() {
    private val eventId = MutableStateFlow<Long?>(null)
    private val query = MutableStateFlow("")
    private val selectedAttendeeId = MutableStateFlow<Long?>(null)

    private val results =
        combine(eventId, query) { currentEventId, currentQuery ->
            currentEventId to currentQuery
        }.flatMapLatest { (currentEventId, currentQuery) ->
            if (currentEventId == null) {
                flowOf(emptyList())
            } else {
                attendeeLookupRepository.search(currentEventId, currentQuery)
            }
        }

    private val selectedResult =
        combine(results, selectedAttendeeId) { currentResults, attendeeId ->
            currentResults.firstOrNull { it.id == attendeeId }
        }

    val uiState: StateFlow<AttendeeSearchUiState> =
        combine(query, results, selectedResult) { currentQuery, currentResults, currentSelection ->
            AttendeeSearchUiState(
                query = currentQuery,
                selectedResult = currentSelection?.toUiModel(),
                results = currentResults.map { it.toUiModel() },
                emptyState =
                    when {
                        currentSelection != null -> SearchEmptyState.Hidden
                        currentQuery.isBlank() -> SearchEmptyState.Prompt
                        currentResults.isEmpty() -> SearchEmptyState.NoResults
                        else -> SearchEmptyState.Hidden
                    }
            )
        }.stateIn(
            scope = viewModelScope,
            started = SharingStarted.Eagerly,
            initialValue = AttendeeSearchUiState()
        )

    fun setEventId(eventId: Long) {
        this.eventId.update { current ->
            if (current == eventId) {
                current
            } else {
                selectedAttendeeId.value = null
                query.value = ""
                eventId
            }
        }
    }

    fun updateQuery(value: String) {
        query.value = value
        if (selectedAttendeeId.value != null) {
            selectedAttendeeId.value = null
        }
    }

    fun selectAttendee(attendeeId: Long) {
        selectedAttendeeId.value = attendeeId
    }

    fun clearSelection() {
        selectedAttendeeId.value = null
    }

    private fun AttendeeSearchRecord.toUiModel(): AttendeeSearchResultUiModel {
        val statusTone =
            when {
                isCurrentlyInside -> StatusTone.Success
                checkinsRemaining <= 0 -> StatusTone.Warning
                else -> paymentStatus.toPaymentUiState().tone
            }

        val statusLabel =
            when {
                isCurrentlyInside -> "Currently inside"
                checkinsRemaining <= 0 -> "No local check-ins remaining"
                else -> paymentStatus.toPaymentUiState().defaultLabel
            }

        val supportingParts =
            listOfNotNull(
                email?.takeIf { it.isNotBlank() },
                ticketType?.takeIf { it.isNotBlank() }
            )

        return AttendeeSearchResultUiModel(
            id = id,
            displayName = displayName,
            ticketCode = ticketCode,
            supportingText = supportingParts.joinToString(" • ").ifBlank { "Ticket $ticketCode" },
            statusLabel = statusLabel,
            statusTone = statusTone
        )
    }
}
