package za.co.voelgoed.fastcheck.data.local

data class EventAttendeeMetricsProjection(
    val cachedAttendeeCount: Int,
    val currentlyInsideCount: Int,
    val attendeesWithRemainingCheckinsCount: Int
)
