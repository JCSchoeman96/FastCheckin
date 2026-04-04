package za.co.voelgoed.fastcheck.data.repository

import kotlinx.coroutines.flow.Flow
import za.co.voelgoed.fastcheck.domain.model.EventAttendeeCacheMetrics

interface EventAttendeeMetricsRepository {
    fun observeMetrics(eventId: Long): Flow<EventAttendeeCacheMetrics>
}
