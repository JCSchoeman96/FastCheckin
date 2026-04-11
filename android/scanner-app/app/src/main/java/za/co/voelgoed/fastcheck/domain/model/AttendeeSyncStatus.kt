package za.co.voelgoed.fastcheck.domain.model

data class AttendeeSyncStatus(
    val eventId: Long,
    val lastServerTime: String?,
    val lastSuccessfulSyncAt: String?,
    val syncType: String?,
    val attendeeCount: Int,
    val bootstrapCompletedAt: String? = null,
    val lastAttemptedSyncAt: String? = null,
    val consecutiveFailures: Int = 0,
    val lastErrorCode: String? = null,
    val lastErrorAt: String? = null,
    val lastFullReconcileAt: String? = null,
    val incrementalCyclesSinceFullReconcile: Int = 0,
    val consecutiveIntegrityFailures: Int = 0
)
