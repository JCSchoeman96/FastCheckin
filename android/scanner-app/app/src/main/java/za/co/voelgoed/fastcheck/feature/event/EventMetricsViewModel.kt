package za.co.voelgoed.fastcheck.feature.event

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import javax.inject.Inject
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.stateIn
import za.co.voelgoed.fastcheck.data.repository.EventAttendeeMetricsRepository
import za.co.voelgoed.fastcheck.domain.model.EventAttendeeCacheMetrics

@HiltViewModel
@OptIn(ExperimentalCoroutinesApi::class)
class EventMetricsViewModel @Inject constructor(
    private val eventAttendeeMetricsRepository: EventAttendeeMetricsRepository
) : ViewModel() {
    private val observedSession = MutableStateFlow<ObservedEventSession?>(null)

    val attendeeMetrics: StateFlow<EventAttendeeCacheMetrics?> =
        observedSession
            .flatMapLatest(::metricsFlowFor)
            .stateIn(viewModelScope, kotlinx.coroutines.flow.SharingStarted.WhileSubscribed(5_000), null)

    fun observeSession(eventId: Long, authenticatedAtEpochMillis: Long) {
        val nextSession =
            ObservedEventSession(
                eventId = eventId,
                authenticatedAtEpochMillis = authenticatedAtEpochMillis
            )
        if (observedSession.value == nextSession) return
        observedSession.value = nextSession
    }

    private fun metricsFlowFor(session: ObservedEventSession?): Flow<EventAttendeeCacheMetrics?> =
        if (session == null) {
            flowOf(null)
        } else {
            eventAttendeeMetricsRepository.observeMetrics(session.eventId)
        }

    private data class ObservedEventSession(
        val eventId: Long,
        val authenticatedAtEpochMillis: Long
    )
}
