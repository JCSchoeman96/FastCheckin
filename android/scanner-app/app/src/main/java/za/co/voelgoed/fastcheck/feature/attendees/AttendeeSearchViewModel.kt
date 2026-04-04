package za.co.voelgoed.fastcheck.feature.attendees

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import javax.inject.Inject
import kotlinx.coroutines.CancellationException
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
import kotlinx.coroutines.launch
import za.co.voelgoed.fastcheck.core.autoflush.AutoFlushCoordinator
import za.co.voelgoed.fastcheck.core.autoflush.AutoFlushTrigger
import za.co.voelgoed.fastcheck.core.designsystem.semantic.StatusTone
import za.co.voelgoed.fastcheck.core.designsystem.semantic.toAttendanceUiState
import za.co.voelgoed.fastcheck.core.designsystem.semantic.toPaymentUiState
import za.co.voelgoed.fastcheck.data.repository.AttendeeLookupRepository
import za.co.voelgoed.fastcheck.domain.model.AttendeeDetailRecord
import za.co.voelgoed.fastcheck.domain.model.AttendeeSearchRecord
import za.co.voelgoed.fastcheck.domain.model.QueueCreationResult
import za.co.voelgoed.fastcheck.domain.model.ScanDirection
import za.co.voelgoed.fastcheck.domain.usecase.QueueCapturedScanUseCase

@HiltViewModel
@OptIn(ExperimentalCoroutinesApi::class)
class AttendeeSearchViewModel @Inject constructor(
    private val attendeeLookupRepository: AttendeeLookupRepository,
    private val queueCapturedScanUseCase: QueueCapturedScanUseCase,
    private val autoFlushCoordinator: AutoFlushCoordinator
) : ViewModel() {
    private val eventId = MutableStateFlow<Long?>(null)
    private val query = MutableStateFlow("")
    private val selectedAttendeeId = MutableStateFlow<Long?>(null)
    private val actionBanner = MutableStateFlow<AttendeeSearchBannerUiModel?>(null)
    private val isSubmittingManualCheckIn = MutableStateFlow(false)

    private val results: StateFlow<List<AttendeeSearchRecord>> =
        combine(eventId, query) { currentEventId, currentQuery ->
            currentEventId to currentQuery
        }.flatMapLatest { (currentEventId, currentQuery) ->
            if (currentEventId == null) {
                flowOf(emptyList())
            } else {
                attendeeLookupRepository.search(currentEventId, currentQuery)
            }
        }.stateIn(
            scope = viewModelScope,
            started = SharingStarted.Eagerly,
            initialValue = emptyList()
        )

    private val selectedAttendee: StateFlow<AttendeeDetailRecord?> =
        combine(eventId, selectedAttendeeId) { currentEventId, attendeeId ->
            currentEventId to attendeeId
        }.flatMapLatest { (currentEventId, attendeeId) ->
            if (currentEventId == null || attendeeId == null) {
                flowOf(null)
            } else {
                attendeeLookupRepository.observeDetail(currentEventId, attendeeId)
            }
        }.stateIn(
            scope = viewModelScope,
            started = SharingStarted.Eagerly,
            initialValue = null
        )

    private val selectionState: StateFlow<SelectionState> =
        combine(
            selectedAttendeeId,
            selectedAttendee,
            actionBanner,
            isSubmittingManualCheckIn
        ) { currentSelectedAttendeeId, currentSelectedAttendee, currentActionBanner, submitting ->
            SelectionState(
                selectedAttendeeId = currentSelectedAttendeeId,
                selectedAttendee = currentSelectedAttendee,
                actionBanner = currentActionBanner,
                isSubmittingManualCheckIn = submitting
            )
        }.stateIn(
            scope = viewModelScope,
            started = SharingStarted.Eagerly,
            initialValue = SelectionState()
        )

    val uiState: StateFlow<AttendeeSearchUiState> =
        combine(query, results, selectionState) { currentQuery, currentResults, currentSelection ->
            AttendeeSearchUiState(
                query = currentQuery,
                actionBanner = currentSelection.actionBanner,
                selectedAttendee = currentSelection.selectedAttendee?.toUiModel(),
                results = currentResults.map { it.toUiModel() },
                emptyState =
                    when {
                        currentSelection.selectedAttendeeId != null -> SearchEmptyState.Hidden
                        currentQuery.isBlank() -> SearchEmptyState.Prompt
                        currentResults.isEmpty() -> SearchEmptyState.NoResults
                        else -> SearchEmptyState.Hidden
                    },
                isShowingSelection = currentSelection.selectedAttendeeId != null,
                isSubmittingManualCheckIn = currentSelection.isSubmittingManualCheckIn
            )
        }.stateIn(
            scope = viewModelScope,
            started = SharingStarted.Eagerly,
            initialValue = AttendeeSearchUiState()
        )

    fun setEventId(eventId: Long) {
        resetSearchState()
        this.eventId.update { current ->
            if (current == eventId) {
                current
            } else {
                eventId
            }
        }
    }

    fun updateQuery(value: String) {
        query.value = value
        actionBanner.value = null
        if (selectedAttendeeId.value != null) {
            selectedAttendeeId.value = null
        }
    }

    fun selectAttendee(attendeeId: Long) {
        selectedAttendeeId.value = attendeeId
        actionBanner.value = null
    }

    fun clearSelection() {
        selectedAttendeeId.value = null
        actionBanner.value = null
    }

    fun dismissActionBanner() {
        actionBanner.value = null
    }

    fun queueManualCheckIn() {
        val attendee = selectedAttendee.value ?: return
        if (isSubmittingManualCheckIn.value) return

        viewModelScope.launch {
            isSubmittingManualCheckIn.value = true
            try {
                val result =
                    queueCapturedScanUseCase.enqueue(
                        ticketCode = attendee.ticketCode,
                        direction = ScanDirection.IN,
                        operatorName = FALLBACK_OPERATOR_NAME,
                        entranceName = MANUAL_ENTRANCE_NAME
                    )

                val stillSelected = selectedAttendeeId.value == attendee.id
                actionBanner.value = if (stillSelected) result.toActionBanner(attendee.ticketCode) else null

                if (result is QueueCreationResult.Enqueued) {
                    autoFlushCoordinator.requestFlush(AutoFlushTrigger.AfterEnqueue)
                }
            } catch (error: Throwable) {
                if (error is CancellationException) {
                    throw error
                }

                val stillSelected = selectedAttendeeId.value == attendee.id
                actionBanner.value = if (stillSelected) queueFailureBanner() else null
            } finally {
                isSubmittingManualCheckIn.value = false
            }
        }
    }

    private fun resetSearchState() {
        selectedAttendeeId.value = null
        query.value = ""
        actionBanner.value = null
        isSubmittingManualCheckIn.value = false
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

    private fun AttendeeDetailRecord.toUiModel(): AttendeeDetailUiModel {
        val paymentState = paymentStatus.toPaymentUiState()
        val attendanceState = toAttendanceUiState(checkedInAt, checkedOutAt, isCurrentlyInside)

        return AttendeeDetailUiModel(
            id = id,
            displayName = displayName,
            ticketCode = ticketCode,
            email = email,
            ticketType = ticketType,
            paymentLabel = paymentState.defaultLabel,
            paymentTone = paymentState.tone,
            attendanceLabel = attendanceState.defaultLabel,
            attendanceTone = attendanceState.tone,
            allowedCheckinsLabel = "Allowed check-ins: $allowedCheckins",
            remainingCheckinsLabel = "Remaining check-ins: $checkinsRemaining",
            checkedInAt = checkedInAt,
            checkedOutAt = checkedOutAt,
            updatedAt = updatedAt
        )
    }

    private fun QueueCreationResult.toActionBanner(ticketCode: String): AttendeeSearchBannerUiModel =
        when (this) {
            is QueueCreationResult.Enqueued ->
                AttendeeSearchBannerUiModel(
                    title = "Queued locally",
                    message =
                        "Manual IN scan for $ticketCode is queued locally. Server confirmation is still pending upload.",
                    tone = StatusTone.Info
                )

            QueueCreationResult.ReplaySuppressed ->
                AttendeeSearchBannerUiModel(
                    title = "Already queued locally",
                    message =
                        "A repeated manual action for $ticketCode was ignored inside the local replay window. No new upload was queued.",
                    tone = StatusTone.Duplicate
                )

            QueueCreationResult.MissingSessionContext ->
                AttendeeSearchBannerUiModel(
                    title = "Login required",
                    message = "Manual check-in needs an active session before the ticket can be queued.",
                    tone = StatusTone.Destructive
                )

            QueueCreationResult.InvalidTicketCode ->
                AttendeeSearchBannerUiModel(
                    title = "Ticket unavailable",
                    message = "Manual check-in could not be queued because the ticket code is invalid.",
                    tone = StatusTone.Destructive
                )
        }

    private fun queueFailureBanner(): AttendeeSearchBannerUiModel =
        AttendeeSearchBannerUiModel(
            title = "Could not queue locally",
            message = "Manual check-in could not be queued locally. Try again.",
            tone = StatusTone.Destructive
        )

    private companion object {
        const val FALLBACK_OPERATOR_NAME = "Attendee Search"
        const val MANUAL_ENTRANCE_NAME = "Attendee Search"
    }
}

private data class SelectionState(
    val selectedAttendeeId: Long? = null,
    val selectedAttendee: AttendeeDetailRecord? = null,
    val actionBanner: AttendeeSearchBannerUiModel? = null,
    val isSubmittingManualCheckIn: Boolean = false
)
