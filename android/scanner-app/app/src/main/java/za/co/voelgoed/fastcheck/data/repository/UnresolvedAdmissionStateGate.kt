package za.co.voelgoed.fastcheck.data.repository

import javax.inject.Inject
import javax.inject.Singleton
import za.co.voelgoed.fastcheck.data.local.ScannerDao

@Singleton
class UnresolvedAdmissionStateGate private constructor(
    private val unresolvedEventIdsLoader: suspend (Long) -> List<Long>
) {
    @Inject
    constructor(
        scannerDao: ScannerDao
    ) : this(scannerDao::loadUnresolvedEventIdsExcluding)

    suspend fun unresolvedOtherEventIds(targetEventId: Long): List<Long> =
        unresolvedEventIdsLoader(targetEventId)

    suspend fun requireNoConflictingEvents(targetEventId: Long) {
        val unresolvedOtherEvents = unresolvedOtherEventIds(targetEventId)
        if (unresolvedOtherEvents.isNotEmpty()) {
            throw CrossEventUnresolvedStateException(
                targetEventId = targetEventId,
                unresolvedEventIds = unresolvedOtherEvents
            )
        }
    }

    companion object {
        fun fromLoader(
            loader: suspend (Long) -> List<Long>
        ): UnresolvedAdmissionStateGate = UnresolvedAdmissionStateGate(loader)
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
