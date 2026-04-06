package za.co.voelgoed.fastcheck.data.repository

import javax.inject.Inject
import javax.inject.Singleton
import za.co.voelgoed.fastcheck.data.local.ScannerDao

@Singleton
class UnresolvedAdmissionStateGate @Inject constructor(
    private val scannerDao: ScannerDao
) {
    suspend fun unresolvedOtherEventIds(targetEventId: Long): List<Long> =
        scannerDao.loadUnresolvedEventIdsExcluding(targetEventId)

    suspend fun requireNoConflictingEvents(targetEventId: Long) {
        val unresolvedOtherEvents = unresolvedOtherEventIds(targetEventId)
        if (unresolvedOtherEvents.isNotEmpty()) {
            throw CrossEventUnresolvedStateException(
                targetEventId = targetEventId,
                unresolvedEventIds = unresolvedOtherEvents
            )
        }
    }
}

class CrossEventUnresolvedStateException(
    targetEventId: Long,
    unresolvedEventIds: List<Long>
) : RuntimeException(
        buildString {
            append("Unresolved local gate state exists for ")
            append(
                unresolvedEventIds.joinToString(
                    separator = ", ",
                    prefix = "event ",
                    transform = Long::toString
                )
            )
            append(". Resolve that event before switching to event #")
            append(targetEventId)
            append(".")
        }
    )
