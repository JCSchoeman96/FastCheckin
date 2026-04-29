package za.co.voelgoed.fastcheck.core.datastore

data class SessionMetadata(
    val eventId: Long,
    val eventName: String,
    val eventShortname: String? = null,
    val expiresInSeconds: Int,
    val authenticatedAtEpochMillis: Long,
    val expiresAtEpochMillis: Long,
    val lastSyncCursor: String? = null
)
