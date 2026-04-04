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
    private val observedEventId = MutableStateFlow<Long?>(null)

    val attendeeMetrics: StateFlow<EventAttendeeCacheMetrics?> =
        observedEventId
            .flatMapLatest(::metricsFlowFor)
            .stateIn(viewModelScope, kotlinx.coroutines.flow.SharingStarted.WhileSubscribed(5_000), null)

    fun observeEvent(eventId: Long) {
        if (observedEventId.value == eventId) return
        observedEventId.value = eventId
    }

    private fun metricsFlowFor(eventId: Long?): Flow<EventAttendeeCacheMetrics?> =
        if (eventId == null) {
            flowOf(null)
        } else {
            eventAttendeeMetricsRepository.observeMetrics(eventId)
        }
}
