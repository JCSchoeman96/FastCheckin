package za.co.voelgoed.fastcheck.domain.model

data class EventAttendeeCacheMetrics(
    val cachedAttendeeCount: Int,
    val currentlyInsideCount: Int,
    val attendeesWithRemainingCheckinsCount: Int,
    val activeOverlayCount: Int,
    val unresolvedConflictCount: Int
)
