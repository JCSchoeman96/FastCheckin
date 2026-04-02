/**
 * Semantic UI state for sync and flush presentation.
 *
 * Sync truth stays projection-only in the UI layer. Durable queue data lives in
 * Room/repositories and transient orchestration truth lives in the coordinator.
 */
package za.co.voelgoed.fastcheck.core.designsystem.semantic

sealed interface SyncUiState {
    val tone: StatusTone
    val iconKey: String
    val labelHook: String
    val defaultLabel: String

    data object Idle : SyncUiState {
        override val tone: StatusTone = StatusTone.Neutral
        override val iconKey: String = "sync_idle"
        override val labelHook: String = "sync.idle"
        override val defaultLabel: String = "Idle"
    }

    data object Syncing : SyncUiState {
        override val tone: StatusTone = StatusTone.Info
        override val iconKey: String = "sync_syncing"
        override val labelHook: String = "sync.syncing"
        override val defaultLabel: String = "Uploading"
    }

    data class Synced(
        val uploadedCount: Int? = null
    ) : SyncUiState {
        override val tone: StatusTone = StatusTone.Success
        override val iconKey: String = "sync_synced"
        override val labelHook: String = "sync.synced"
        override val defaultLabel: String = "Synced"
    }

    data class Partial(
        val backlogRemainingCount: Int? = null
    ) : SyncUiState {
        override val tone: StatusTone = StatusTone.Warning
        override val iconKey: String = "sync_partial"
        override val labelHook: String = "sync.partial"
        override val defaultLabel: String = "Synced with backlog remaining"
    }

    data class Failed(
        val reason: String? = null
    ) : SyncUiState {
        override val tone: StatusTone = StatusTone.Destructive
        override val iconKey: String = "sync_failed"
        override val labelHook: String = "sync.failed"
        override val defaultLabel: String =
            reason?.takeIf { it.isNotBlank() } ?: "Failed"
    }

    data class Offline(
        val reason: String? = null
    ) : SyncUiState {
        override val tone: StatusTone = StatusTone.Offline
        override val iconKey: String = "sync_offline"
        override val labelHook: String = "sync.offline"
        override val defaultLabel: String =
            reason?.takeIf { it.isNotBlank() } ?: "Offline"
    }

    data class RetryScheduled(
        val attempt: Int,
        val nextRetryAtEpochMs: Long? = null
    ) : SyncUiState {
        override val tone: StatusTone = StatusTone.Warning
        override val iconKey: String = "sync_retry_scheduled"
        override val labelHook: String = "sync.retry_scheduled"
        override val defaultLabel: String =
            if (attempt > 0) {
                "Retry pending (attempt $attempt)"
            } else {
                "Retry pending"
            }
    }
}
