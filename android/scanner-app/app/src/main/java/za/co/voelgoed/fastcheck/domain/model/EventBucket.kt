package za.co.voelgoed.fastcheck.domain.model

data class EventBucket(
    val eventId: Long,
    val eventName: String?,
    val eventShortname: String?,
    val state: String,
    val pendingUploadCount: Int,
    val awaitingReconciliationCount: Int,
    val conflictCount: Int,
    val quarantinedCount: Int,
    val updatedAtEpochMillis: Long,
    val lastFlushAttemptAtEpochMillis: Long? = null,
    val lastSyncAttempt: String? = null
)
