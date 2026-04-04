package za.co.voelgoed.fastcheck.data.repository

import kotlinx.coroutines.flow.Flow
import za.co.voelgoed.fastcheck.domain.model.AttendeeDetailRecord
import za.co.voelgoed.fastcheck.domain.model.AttendeeSearchRecord

interface AttendeeLookupRepository {
    fun search(eventId: Long, query: String): Flow<List<AttendeeSearchRecord>>

    fun observeDetail(eventId: Long, attendeeId: Long): Flow<AttendeeDetailRecord?>
}
