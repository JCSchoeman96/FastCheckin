package za.co.voelgoed.fastcheck.core.designsystem.semantic

import za.co.voelgoed.fastcheck.core.autoflush.AutoFlushCoordinatorState
import za.co.voelgoed.fastcheck.domain.model.FlushExecutionStatus
import za.co.voelgoed.fastcheck.domain.model.FlushReport

fun AutoFlushCoordinatorState.toSyncUiState(
    isOnline: Boolean,
    latestFlushReport: FlushReport? = null,
    pendingQueueDepth: Int = 0
): SyncUiState {
    if (isFlushing) {
        return SyncUiState.Syncing
    }

    if (isRetryScheduled) {
        return SyncUiState.RetryScheduled(
            attempt = retryAttempt,
            nextRetryAtEpochMs = nextRetryAtEpochMs
        )
    }

    if (!isOnline) {
        return SyncUiState.Offline()
    }

    val report = latestFlushReport ?: lastFlushReport ?: return SyncUiState.Idle

    return when (report.executionStatus) {
        FlushExecutionStatus.COMPLETED ->
            if (report.backlogRemaining || pendingQueueDepth > 0) {
                SyncUiState.Partial(
                    backlogRemainingCount =
                        maxOf(pendingQueueDepth, report.retryableRemainingCount)
                )
            } else {
                SyncUiState.Synced(uploadedCount = report.uploadedCount)
            }

        FlushExecutionStatus.AUTH_EXPIRED ->
            SyncUiState.Failed(reason = "Auth expired")

        FlushExecutionStatus.RETRYABLE_FAILURE ->
            SyncUiState.Failed(reason = "Retry failed")

        FlushExecutionStatus.WORKER_FAILURE ->
            SyncUiState.Failed(reason = "Failed")
    }
}

fun FlushReport.toSyncUiState(
    isOnline: Boolean,
    pendingQueueDepth: Int = 0
): SyncUiState =
    AutoFlushCoordinatorState(
        isFlushing = false,
        lastFlushReport = this,
        isRetryScheduled = false,
        retryAttempt = 0,
        nextRetryAtEpochMs = null
    ).toSyncUiState(
        isOnline = isOnline,
        latestFlushReport = this,
        pendingQueueDepth = pendingQueueDepth
    )
