package za.co.voelgoed.fastcheck.data.local

import androidx.room.Dao
import androidx.room.Query
import kotlinx.coroutines.flow.Flow

@Dao
interface AttendeeLookupDao {
    @Query("SELECT * FROM attendees WHERE eventId = :eventId AND id = :attendeeId LIMIT 1")
    fun observeAttendeeById(eventId: Long, attendeeId: Long): Flow<AttendeeEntity?>

    @Query(
        """
        SELECT * FROM attendees
        WHERE eventId = :eventId
            AND (
                (:exactTicketCode != '' AND ticketCode = :exactTicketCode)
                OR (:prefixQuery != '' AND ticketCode LIKE :prefixQuery ESCAPE '\')
                OR (
                    :containsQuery != ''
                    AND (
                        lower(COALESCE(firstName, '')) LIKE :containsQuery ESCAPE '\'
                        OR lower(COALESCE(lastName, '')) LIKE :containsQuery ESCAPE '\'
                        OR lower(COALESCE(email, '')) LIKE :containsQuery ESCAPE '\'
                    )
                )
            )
        LIMIT :limit
        """
    )
    fun observeSearchCandidates(
        eventId: Long,
        exactTicketCode: String,
        prefixQuery: String,
        containsQuery: String,
        limit: Int
    ): Flow<List<AttendeeEntity>>
}
