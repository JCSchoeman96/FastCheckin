package za.co.voelgoed.fastcheck.data.local

import androidx.room.Dao
import androidx.room.Query
import kotlinx.coroutines.flow.Flow

@Dao
interface AttendeeLookupDao {
    @Query(
        """
        SELECT
            attendee.id AS id,
            attendee.eventId AS eventId,
            attendee.ticketCode AS ticketCode,
            attendee.firstName AS firstName,
            attendee.lastName AS lastName,
            attendee.email AS email,
            attendee.ticketType AS ticketType,
            attendee.allowedCheckins AS allowedCheckins,
            attendee.paymentStatus AS paymentStatus,
            attendee.updatedAt AS updatedAt,
            CASE
                WHEN overlay.id IS NOT NULL THEN
                    CASE
                        WHEN attendee.checkinsRemaining > 0 THEN attendee.checkinsRemaining - 1
                        ELSE 0
                    END
                ELSE attendee.checkinsRemaining
            END AS mergedCheckinsRemaining,
            CASE
                WHEN overlay.id IS NOT NULL THEN 1
                ELSE attendee.isCurrentlyInside
            END AS mergedIsCurrentlyInside,
            CASE
                WHEN overlay.id IS NOT NULL THEN overlay.overlayScannedAt
                ELSE attendee.checkedInAt
            END AS mergedCheckedInAt,
            CASE
                WHEN overlay.id IS NOT NULL THEN NULL
                ELSE attendee.checkedOutAt
            END AS mergedCheckedOutAt,
            overlay.state AS activeOverlayState,
            overlay.conflictReasonCode AS activeOverlayConflictReasonCode,
            overlay.conflictMessage AS activeOverlayConflictMessage,
            overlay.overlayScannedAt AS activeOverlayScannedAt,
            overlay.expectedRemainingAfterOverlay AS expectedRemainingAfterOverlay
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
        WHERE attendee.eventId = :eventId AND attendee.id = :attendeeId
        LIMIT 1
        """
    )
    fun observeAttendeeById(eventId: Long, attendeeId: Long): Flow<MergedAttendeeLookupProjection?>

    @Query(
        """
        SELECT
            attendee.id AS id,
            attendee.eventId AS eventId,
            attendee.ticketCode AS ticketCode,
            attendee.firstName AS firstName,
            attendee.lastName AS lastName,
            attendee.email AS email,
            attendee.ticketType AS ticketType,
            attendee.allowedCheckins AS allowedCheckins,
            attendee.paymentStatus AS paymentStatus,
            attendee.updatedAt AS updatedAt,
            CASE
                WHEN overlay.id IS NOT NULL THEN
                    CASE
                        WHEN attendee.checkinsRemaining > 0 THEN attendee.checkinsRemaining - 1
                        ELSE 0
                    END
                ELSE attendee.checkinsRemaining
            END AS mergedCheckinsRemaining,
            CASE
                WHEN overlay.id IS NOT NULL THEN 1
                ELSE attendee.isCurrentlyInside
            END AS mergedIsCurrentlyInside,
            CASE
                WHEN overlay.id IS NOT NULL THEN overlay.overlayScannedAt
                ELSE attendee.checkedInAt
            END AS mergedCheckedInAt,
            CASE
                WHEN overlay.id IS NOT NULL THEN NULL
                ELSE attendee.checkedOutAt
            END AS mergedCheckedOutAt,
            overlay.state AS activeOverlayState,
            overlay.conflictReasonCode AS activeOverlayConflictReasonCode,
            overlay.conflictMessage AS activeOverlayConflictMessage,
            overlay.overlayScannedAt AS activeOverlayScannedAt,
            overlay.expectedRemainingAfterOverlay AS expectedRemainingAfterOverlay
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
        WHERE attendee.eventId = :eventId AND attendee.ticketCode = :ticketCode
        LIMIT 1
        """
    )
    suspend fun findMergedAttendeeByTicketCode(
        eventId: Long,
        ticketCode: String
    ): MergedAttendeeLookupProjection?

    @Query(
        """
        SELECT
            attendee.id AS id,
            attendee.eventId AS eventId,
            attendee.ticketCode AS ticketCode,
            attendee.firstName AS firstName,
            attendee.lastName AS lastName,
            attendee.email AS email,
            attendee.ticketType AS ticketType,
            attendee.allowedCheckins AS allowedCheckins,
            attendee.paymentStatus AS paymentStatus,
            attendee.updatedAt AS updatedAt,
            CASE
                WHEN overlay.id IS NOT NULL THEN
                    CASE
                        WHEN attendee.checkinsRemaining > 0 THEN attendee.checkinsRemaining - 1
                        ELSE 0
                    END
                ELSE attendee.checkinsRemaining
            END AS mergedCheckinsRemaining,
            CASE
                WHEN overlay.id IS NOT NULL THEN 1
                ELSE attendee.isCurrentlyInside
            END AS mergedIsCurrentlyInside,
            CASE
                WHEN overlay.id IS NOT NULL THEN overlay.overlayScannedAt
                ELSE attendee.checkedInAt
            END AS mergedCheckedInAt,
            CASE
                WHEN overlay.id IS NOT NULL THEN NULL
                ELSE attendee.checkedOutAt
            END AS mergedCheckedOutAt,
            overlay.state AS activeOverlayState,
            overlay.conflictReasonCode AS activeOverlayConflictReasonCode,
            overlay.conflictMessage AS activeOverlayConflictMessage,
            overlay.overlayScannedAt AS activeOverlayScannedAt,
            overlay.expectedRemainingAfterOverlay AS expectedRemainingAfterOverlay
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
            AND (
                (:exactTicketCode != '' AND attendee.ticketCode = :exactTicketCode)
                OR (:prefixQuery != '' AND attendee.ticketCode LIKE :prefixQuery ESCAPE '\')
                OR (
                    :containsQuery != ''
                    AND (
                        lower(COALESCE(attendee.firstName, '')) LIKE :containsQuery ESCAPE '\'
                        OR lower(COALESCE(attendee.lastName, '')) LIKE :containsQuery ESCAPE '\'
                        OR lower(COALESCE(attendee.email, '')) LIKE :containsQuery ESCAPE '\'
                    )
                )
            )
        ORDER BY
            CASE
                WHEN :exactTicketCode != '' AND attendee.ticketCode = :exactTicketCode THEN 0
                WHEN :prefixQuery != '' AND attendee.ticketCode LIKE :prefixQuery ESCAPE '\' THEN 1
                ELSE 2
            END,
            lower(COALESCE(attendee.lastName, '')),
            lower(COALESCE(attendee.firstName, '')),
            lower(COALESCE(attendee.email, '')),
            attendee.ticketCode,
            attendee.id
        LIMIT :limit
        """
    )
    fun observeSearchCandidates(
        eventId: Long,
        exactTicketCode: String,
        prefixQuery: String,
        containsQuery: String,
        limit: Int
    ): Flow<List<MergedAttendeeLookupProjection>>
}
