package za.co.voelgoed.fastcheck.data.local

import androidx.room.Dao
import androidx.room.Query
import kotlinx.coroutines.flow.Flow

@Dao
interface EventAttendeeMetricsDao {
    @Query(
        """
        SELECT
            COUNT(*) AS cachedAttendeeCount,
            COALESCE(SUM(CASE WHEN isCurrentlyInside = 1 THEN 1 ELSE 0 END), 0) AS currentlyInsideCount,
            COALESCE(SUM(CASE WHEN checkinsRemaining > 0 THEN 1 ELSE 0 END), 0) AS attendeesWithRemainingCheckinsCount
        FROM attendees
        WHERE eventId = :eventId
        """
    )
    fun observeMetrics(eventId: Long): Flow<EventAttendeeMetricsProjection>
}
