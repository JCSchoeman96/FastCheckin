package za.co.voelgoed.fastcheck.feature.sync

enum class BootstrapSyncStatus {
    Idle,
    Syncing,
    Failed,
    Succeeded
}

data class SyncScreenUiState(
    val isSyncing: Boolean = false,
    val summaryMessage: String = "No attendee sync has run yet.",
    val errorMessage: String? = null,
    val isRateLimited: Boolean = false,
    val nextAllowedSyncAtMillis: Long? = null,
    val bootstrapStatus: BootstrapSyncStatus = BootstrapSyncStatus.Idle,
    val bootstrapEventId: Long? = null
)
