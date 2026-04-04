package za.co.voelgoed.fastcheck.data.repository

import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map
import za.co.voelgoed.fastcheck.data.local.EventAttendeeMetricsDao
import za.co.voelgoed.fastcheck.domain.model.EventAttendeeCacheMetrics

@Singleton
class CurrentEventAttendeeMetricsRepository @Inject constructor(
    private val eventAttendeeMetricsDao: EventAttendeeMetricsDao
) : EventAttendeeMetricsRepository {
    override fun observeMetrics(eventId: Long): Flow<EventAttendeeCacheMetrics> =
        eventAttendeeMetricsDao.observeMetrics(eventId).map { projection ->
            EventAttendeeCacheMetrics(
                cachedAttendeeCount = projection.cachedAttendeeCount,
                currentlyInsideCount = projection.currentlyInsideCount,
                attendeesWithRemainingCheckinsCount = projection.attendeesWithRemainingCheckinsCount
            )
        }
}
