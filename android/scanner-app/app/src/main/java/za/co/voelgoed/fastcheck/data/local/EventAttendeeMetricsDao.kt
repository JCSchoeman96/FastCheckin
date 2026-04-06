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
            COALESCE(SUM(
                CASE
                    WHEN overlay.id IS NOT NULL THEN 1
                    WHEN attendee.isCurrentlyInside = 1 THEN 1
                    ELSE 0
                END
            ), 0) AS currentlyInsideCount,
            COALESCE(SUM(
                CASE
                    WHEN overlay.id IS NOT NULL THEN
                        CASE
                            WHEN attendee.checkinsRemaining > 0 THEN 1
                            ELSE 0
                        END
                    WHEN attendee.checkinsRemaining > 0 THEN 1
                    ELSE 0
                END
            ), 0) AS attendeesWithRemainingCheckinsCount,
            (
                SELECT COUNT(*)
                FROM local_admission_overlays overlay_count
                WHERE overlay_count.eventId = :eventId
                    AND overlay_count.state IN (
                        'PENDING_LOCAL',
                        'CONFIRMED_LOCAL_UNSYNCED',
                        'CONFLICT_DUPLICATE',
                        'CONFLICT_REJECTED'
                    )
            ) AS activeOverlayCount,
            (
                SELECT COUNT(*)
                FROM local_admission_overlays conflict_count
                WHERE conflict_count.eventId = :eventId
                    AND conflict_count.state IN ('CONFLICT_DUPLICATE', 'CONFLICT_REJECTED')
            ) AS unresolvedConflictCount
        FROM attendees attendee
        LEFT JOIN local_admission_overlays overlay
            ON overlay.id = (
                SELECT candidate.id
                FROM local_admission_overlays candidate
                WHERE candidate.eventId = attendee.eventId
                    AND candidate.attendeeId = attendee.id
                    AND candidate.state IN (
                        'PENDING_LOCAL',
                        'CONFIRMED_LOCAL_UNSYNCED',
                        'CONFLICT_DUPLICATE',
                        'CONFLICT_REJECTED'
                    )
                ORDER BY candidate.createdAtEpochMillis DESC, candidate.id DESC
                LIMIT 1
            )
        WHERE attendee.eventId = :eventId
        """
    )
    fun observeMetrics(eventId: Long): Flow<EventAttendeeMetricsProjection>
}
