package za.co.voelgoed.fastcheck.feature.search

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import javax.inject.Inject
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import za.co.voelgoed.fastcheck.core.autoflush.AutoFlushCoordinator
import za.co.voelgoed.fastcheck.core.autoflush.AutoFlushTrigger
import za.co.voelgoed.fastcheck.core.designsystem.semantic.StatusTone
import za.co.voelgoed.fastcheck.data.repository.AttendeeLookupRepository
import za.co.voelgoed.fastcheck.domain.model.AttendeeDetailRecord
import za.co.voelgoed.fastcheck.domain.model.AttendeeSearchRecord
import za.co.voelgoed.fastcheck.domain.model.LocalAdmissionDecision
import za.co.voelgoed.fastcheck.domain.usecase.AdmitScanUseCase
import za.co.voelgoed.fastcheck.feature.search.detail.model.ManualActionUiState

@HiltViewModel
@OptIn(ExperimentalCoroutinesApi::class)
class SearchViewModel @Inject constructor(
    private val attendeeLookupRepository: AttendeeLookupRepository,
    private val admitScanUseCase: AdmitScanUseCase,
    private val autoFlushCoordinator: AutoFlushCoordinator
) : ViewModel() {
    private val observedSession = MutableStateFlow<ObservedSession?>(null)
    private val query = MutableStateFlow("")
    private val selectedAttendeeId = MutableStateFlow<Long?>(null)
    private val _manualActionUiState = MutableStateFlow(ManualActionUiState())
    val manualActionUiState: StateFlow<ManualActionUiState> = _manualActionUiState.asStateFlow()

    val queryState: StateFlow<String> = query.asStateFlow()

    val results: StateFlow<List<AttendeeSearchRecord>> =
        combine(observedSession, query) { session, queryText -> session to queryText }
            .flatMapLatest { (session, queryText) ->
                resultsFlowFor(session, queryText)
            }
            .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyList())

    val selectedDetail: StateFlow<AttendeeDetailRecord?> =
        combine(observedSession, selectedAttendeeId) { session, attendeeId -> session to attendeeId }
            .flatMapLatest { (session, attendeeId) ->
                detailFlowFor(session, attendeeId)
            }
            .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), null)

    fun observeSession(eventId: Long, authenticatedAtEpochMillis: Long) {
        val next = ObservedSession(eventId, authenticatedAtEpochMillis)
        if (observedSession.value == next) return

        observedSession.value = next
        query.value = ""
        selectedAttendeeId.value = null
        _manualActionUiState.value = ManualActionUiState()
    }

    fun onQueryChanged(value: String) {
        query.value = value
        selectedAttendeeId.value = null
        _manualActionUiState.value = ManualActionUiState()
    }

    fun selectAttendee(attendeeId: Long) {
        selectedAttendeeId.value = attendeeId
        _manualActionUiState.value = ManualActionUiState()
    }

    fun navigateBackToResults() {
        selectedAttendeeId.value = null
    }

    fun clearSearch() {
        query.value = ""
        selectedAttendeeId.value = null
        _manualActionUiState.value = ManualActionUiState()
    }

    fun admitSelectedAttendee() {
        val detail = selectedDetail.value ?: return
        if (_manualActionUiState.value.isRunning) return

        viewModelScope.launch {
            _manualActionUiState.value = ManualActionUiState(isRunning = true)
            when (
                val decision =
                    admitScanUseCase.admit(
                        ticketCode = detail.ticketCode,
                        direction = za.co.voelgoed.fastcheck.domain.model.ScanDirection.IN,
                        operatorName = "Manual Admit",
                        entranceName = "Manual Admit"
                    )
            ) {
                is LocalAdmissionDecision.Accepted -> {
                    autoFlushCoordinator.requestFlush(AutoFlushTrigger.AfterEnqueue)
                    _manualActionUiState.value =
                        ManualActionUiState(
                            isRunning = false,
                            feedbackTitle = "Accepted",
                            feedbackMessage = "Welcome, ${decision.displayName}",
                            feedbackTone = StatusTone.Success
                        )
                }

                is LocalAdmissionDecision.Rejected ->
                    _manualActionUiState.value =
                        ManualActionUiState(
                            isRunning = false,
                            feedbackTitle = "Invalid scan",
                            feedbackMessage = decision.displayMessage,
                            feedbackTone = StatusTone.Warning
                        )

                is LocalAdmissionDecision.ReviewRequired ->
                    _manualActionUiState.value =
                        ManualActionUiState(
                            isRunning = false,
                            feedbackTitle = "Manual review",
                            feedbackMessage = decision.displayMessage,
                            feedbackTone = StatusTone.Warning
                        )

                is LocalAdmissionDecision.OperationalFailure ->
                    _manualActionUiState.value =
                        ManualActionUiState(
                            isRunning = false,
                            feedbackTitle = "Admission failed",
                            feedbackMessage = decision.displayMessage,
                            feedbackTone = StatusTone.Destructive
                        )
            }
        }
    }

    private fun resultsFlowFor(
        session: ObservedSession?,
        queryText: String
    ): Flow<List<AttendeeSearchRecord>> =
        if (session == null) {
            flowOf(emptyList())
        } else {
            attendeeLookupRepository.search(session.eventId, queryText)
        }

    private fun detailFlowFor(
        session: ObservedSession?,
        attendeeId: Long?
    ): Flow<AttendeeDetailRecord?> =
        if (session == null || attendeeId == null) {
            flowOf(null)
        } else {
            attendeeLookupRepository.observeDetail(session.eventId, attendeeId)
        }

    private data class ObservedSession(
        val eventId: Long,
        val authenticatedAtEpochMillis: Long
    )
}
