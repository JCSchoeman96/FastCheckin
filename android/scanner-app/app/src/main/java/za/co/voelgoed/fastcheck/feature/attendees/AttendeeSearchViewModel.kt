package za.co.voelgoed.fastcheck.feature.attendees

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import javax.inject.Inject
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
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
import za.co.voelgoed.fastcheck.data.repository.MobileScanRepository
import za.co.voelgoed.fastcheck.domain.model.AttendeeDetailRecord
import za.co.voelgoed.fastcheck.domain.model.AttendeeSearchRecord
import za.co.voelgoed.fastcheck.domain.model.FlushItemOutcome
import za.co.voelgoed.fastcheck.domain.model.FlushReport
import za.co.voelgoed.fastcheck.domain.model.QueueCreationResult
import za.co.voelgoed.fastcheck.domain.model.ScanDirection
import za.co.voelgoed.fastcheck.domain.usecase.QueueCapturedScanUseCase

@HiltViewModel
@OptIn(ExperimentalCoroutinesApi::class)
class AttendeeSearchViewModel @Inject constructor(
    private val attendeeLookupRepository: AttendeeLookupRepository,
    private val queueCapturedScanUseCase: QueueCapturedScanUseCase,
    private val autoFlushCoordinator: AutoFlushCoordinator,
    mobileScanRepository: MobileScanRepository
) : ViewModel() {
    private val eventId = MutableStateFlow<Long?>(null)
    private val query = MutableStateFlow("")
    private val selectedAttendeeId = MutableStateFlow<Long?>(null)
    private val actionBanner = MutableStateFlow<AttendeeSearchBannerUiModel?>(null)
    private val isSubmittingManualCheckIn = MutableStateFlow(false)

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

    private val selectedAttendee =
        combine(eventId, selectedAttendeeId) { currentEventId, attendeeId ->
            currentEventId to attendeeId
        }.flatMapLatest { (currentEventId, attendeeId) ->
            if (currentEventId == null || attendeeId == null) {
                flowOf(null)
            } else {
                attendeeLookupRepository.observeDetail(currentEventId, attendeeId)
            }
        }

    private val recentUploadBanner =
        combine(selectedAttendee, mobileScanRepository.observeLatestFlushReport()) { attendee, report ->
            buildRecentUploadBanner(attendee, report)
        }

    private val uiInputs =
        combine(query, results, selectedAttendee) { currentQuery, currentResults, currentAttendee ->
            SearchBaseState(
                query = currentQuery,
                results = currentResults,
                selectedAttendee = currentAttendee
            )
        }.combine(actionBanner) { base, currentActionBanner ->
            base to currentActionBanner
        }.combine(recentUploadBanner) { (base, currentActionBanner), currentRecentBanner ->
            SearchBannerState(
                base = base,
                actionBanner = currentActionBanner,
                recentUploadBanner = currentRecentBanner
            )
        }.combine(isSubmittingManualCheckIn) { bannerState, isSubmitting ->
            AttendeeSearchViewStateInputs(
                query = bannerState.base.query,
                results = bannerState.base.results,
                selectedAttendee = bannerState.base.selectedAttendee,
                actionBanner = bannerState.actionBanner,
                recentUploadBanner = bannerState.recentUploadBanner,
                isSubmittingManualCheckIn = isSubmitting
            )
        }

    val uiState: StateFlow<AttendeeSearchUiState> =
        uiInputs.map { inputs ->
            AttendeeSearchUiState(
                query = inputs.query,
                selectedAttendee = inputs.selectedAttendee?.toUiModel(),
                results = inputs.results.map { it.toUiModel() },
                emptyState =
                    when {
                        inputs.selectedAttendee != null -> SearchEmptyState.Hidden
                        inputs.query.isBlank() -> SearchEmptyState.Prompt
                        inputs.results.isEmpty() -> SearchEmptyState.NoResults
                        else -> SearchEmptyState.Hidden
                    },
                actionBanner = inputs.actionBanner,
                recentUploadBanner = inputs.recentUploadBanner,
                isSubmittingManualCheckIn = inputs.isSubmittingManualCheckIn
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
                actionBanner.value = null
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
        val attendee = uiState.value.selectedAttendee ?: return

        viewModelScope.launch {
            isSubmittingManualCheckIn.value = true
            val result =
                queueCapturedScanUseCase.enqueue(
                    ticketCode = attendee.ticketCode,
                    direction = ScanDirection.IN,
                    operatorName = AttendeeSearchActionDefaults.fallbackOperatorName,
                    entranceName = AttendeeSearchActionDefaults.entranceName
                )

            actionBanner.value = result.toActionBanner(attendee.ticketCode)
            isSubmittingManualCheckIn.value = false

            if (result is QueueCreationResult.Enqueued) {
                autoFlushCoordinator.requestFlush(AutoFlushTrigger.AfterEnqueue)
            }
        }
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
            supportingText =
                supportingParts.joinToString(" • ").ifBlank { "Ticket $ticketCode" },
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
                    message = "Manual check-in for $ticketCode is queued locally and pending upload.",
                    tone = StatusTone.Info
                )

            QueueCreationResult.ReplaySuppressed ->
                AttendeeSearchBannerUiModel(
                    title = "Already queued recently",
                    message = "A repeated manual action for $ticketCode was ignored inside the local replay window.",
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

    private fun buildRecentUploadBanner(
        attendee: AttendeeDetailRecord?,
        report: FlushReport?
    ): AttendeeSearchBannerUiModel? {
        val ticketCode = attendee?.ticketCode ?: return null
        val outcome = report?.itemOutcomes?.lastOrNull { it.ticketCode == ticketCode } ?: return null

        val tone =
            when (outcome.outcome) {
                FlushItemOutcome.SUCCESS -> StatusTone.Success
                FlushItemOutcome.DUPLICATE -> StatusTone.Duplicate
                FlushItemOutcome.TERMINAL_ERROR -> StatusTone.Destructive
                FlushItemOutcome.RETRYABLE_FAILURE -> StatusTone.Warning
                FlushItemOutcome.AUTH_EXPIRED -> StatusTone.Warning
            }

        return AttendeeSearchBannerUiModel(
            title = "Latest flush outcome for this ticket",
            message = outcome.message,
            tone = tone
        )
    }
}

private data class AttendeeSearchViewStateInputs(
    val query: String,
    val results: List<AttendeeSearchRecord>,
    val selectedAttendee: AttendeeDetailRecord?,
    val actionBanner: AttendeeSearchBannerUiModel?,
    val recentUploadBanner: AttendeeSearchBannerUiModel?,
    val isSubmittingManualCheckIn: Boolean
)

private data class SearchBaseState(
    val query: String,
    val results: List<AttendeeSearchRecord>,
    val selectedAttendee: AttendeeDetailRecord?
)

private data class SearchBannerState(
    val base: SearchBaseState,
    val actionBanner: AttendeeSearchBannerUiModel?,
    val recentUploadBanner: AttendeeSearchBannerUiModel?
)
