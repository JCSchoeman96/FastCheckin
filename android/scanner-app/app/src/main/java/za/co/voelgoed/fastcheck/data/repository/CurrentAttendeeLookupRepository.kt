package za.co.voelgoed.fastcheck.data.repository

import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.map
import za.co.voelgoed.fastcheck.core.ticket.TicketCodeNormalizer
import za.co.voelgoed.fastcheck.data.local.AttendeeEntity
import za.co.voelgoed.fastcheck.data.local.AttendeeLookupDao
import za.co.voelgoed.fastcheck.data.mapper.toDetailRecord
import za.co.voelgoed.fastcheck.data.mapper.toSearchRecord
import za.co.voelgoed.fastcheck.domain.model.AttendeeDetailRecord
import za.co.voelgoed.fastcheck.domain.model.AttendeeSearchRecord

@Singleton
class CurrentAttendeeLookupRepository @Inject constructor(
    private val attendeeLookupDao: AttendeeLookupDao
) : AttendeeLookupRepository {
    override fun search(eventId: Long, query: String): Flow<List<AttendeeSearchRecord>> {
        val trimmedQuery = query.trim()
        if (trimmedQuery.isBlank()) return flowOf(emptyList())

        val normalizedTicketCode = TicketCodeNormalizer.normalizeOrNull(query).orEmpty()
        val prefixQuery = normalizedTicketCode.toLikePrefixPattern()
        val containsQuery = trimmedQuery.lowercase().toContainsLikePattern()

        return attendeeLookupDao.observeSearchCandidates(
            eventId = eventId,
            exactTicketCode = normalizedTicketCode,
            prefixQuery = prefixQuery,
            containsQuery = containsQuery,
            limit = SEARCH_CANDIDATE_LIMIT
        ).map { candidates ->
            candidates
                .distinctBy(AttendeeEntity::id)
                .sortedWith(searchComparator(trimmedQuery, normalizedTicketCode))
                .take(SEARCH_RESULT_LIMIT)
                .map(AttendeeEntity::toSearchRecord)
        }
    }

    override fun observeDetail(eventId: Long, attendeeId: Long): Flow<AttendeeDetailRecord?> =
        attendeeLookupDao.observeAttendeeById(eventId, attendeeId).map { it?.toDetailRecord() }

    private fun searchComparator(
        rawQuery: String,
        normalizedTicketCode: String
    ): Comparator<AttendeeEntity> {
        val loweredQuery = rawQuery.lowercase()

        return compareByDescending<AttendeeEntity> { it.ticketCode == normalizedTicketCode }
            .thenByDescending { normalizedTicketCode.isNotEmpty() && it.ticketCode.startsWith(normalizedTicketCode) }
            .thenBy { entity ->
                when {
                    entity.lastName.orEmpty().lowercase().contains(loweredQuery) -> 0
                    entity.firstName.orEmpty().lowercase().contains(loweredQuery) -> 1
                    entity.email.orEmpty().lowercase().contains(loweredQuery) -> 2
                    else -> 3
                }
            }
            .thenBy { it.lastName.orEmpty().lowercase() }
            .thenBy { it.firstName.orEmpty().lowercase() }
            .thenBy { it.ticketCode }
    }

    private fun String.toContainsLikePattern(): String =
        "%${escapeLikeWildcards(this)}%"

    private fun String.toLikePrefixPattern(): String =
        if (isBlank()) {
            ""
        } else {
            "${escapeLikeWildcards(this)}%"
        }

    private fun escapeLikeWildcards(value: String): String =
        value
            .replace("\\", "\\\\")
            .replace("%", "\\%")
            .replace("_", "\\_")

    private companion object {
        const val SEARCH_RESULT_LIMIT: Int = 50
        const val SEARCH_CANDIDATE_LIMIT: Int = 150
    }
}
