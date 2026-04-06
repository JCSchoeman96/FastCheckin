/**
 * Shared rules for when manual retry-upload recovery is meaningful for queued work.
 * FastCheckin scanner-app: queue is local durable truth; auth-expired and offline
 * paths are distinct from retryable upload failures.
 */
package za.co.voelgoed.fastcheck.feature.queue

import za.co.voelgoed.fastcheck.core.designsystem.semantic.SyncUiState

object QueueUploadRecoveryVisibility {
    fun shouldShowRetryUpload(queueDepth: Int, uploadState: SyncUiState): Boolean {
        if (queueDepth <= 0) return false
        return when (uploadState) {
            is SyncUiState.Partial -> true
            is SyncUiState.RetryScheduled -> true
            is SyncUiState.Failed -> uploadState.reason != "Auth expired"
            is SyncUiState.Offline -> false
            else -> false
        }
    }
}
