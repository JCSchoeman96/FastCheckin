package za.co.voelgoed.fastcheck.domain.model

data class AttendeeSyncStatus(
    val eventId: Long,
    val lastServerTime: String?,
    val lastSuccessfulSyncAt: String?,
    val syncType: String?,
    val attendeeCount: Int
)
