package za.co.voelgoed.fastcheck.core.designsystem.semantic

import com.google.common.truth.Truth.assertThat
import org.junit.Test
import za.co.voelgoed.fastcheck.core.autoflush.AutoFlushCoordinatorState
import za.co.voelgoed.fastcheck.domain.model.FlushExecutionStatus
import za.co.voelgoed.fastcheck.domain.model.FlushReport

class SyncUiStateMappersTest {
    @Test
    fun flushingWinsOverRetryOfflineAndReportState() {
        val state =
            AutoFlushCoordinatorState(
                isFlushing = true,
                isRetryScheduled = true,
                retryAttempt = 3,
                lastFlushReport =
                    FlushReport(
                        executionStatus = FlushExecutionStatus.AUTH_EXPIRED,
                        authExpired = true,
                        summaryMessage = "offline"
                    )
            ).toSyncUiState(
                isOnline = false,
                latestFlushReport =
                    FlushReport(
                        executionStatus = FlushExecutionStatus.WORKER_FAILURE,
                        summaryMessage = "offline"
                    ),
                pendingQueueDepth = 4
            )

        assertThat(state).isEqualTo(SyncUiState.Syncing)
    }

    @Test
    fun retryScheduledWinsBeforeOfflineAndReportFailure() {
        val state =
            AutoFlushCoordinatorState(
                isRetryScheduled = true,
                retryAttempt = 2,
                nextRetryAtEpochMs = 1_777_777_777_777,
                lastFlushReport =
                    FlushReport(
                        executionStatus = FlushExecutionStatus.AUTH_EXPIRED,
                        authExpired = true,
                        summaryMessage = "offline"
                    )
            ).toSyncUiState(
                isOnline = false,
                latestFlushReport =
                    FlushReport(
                        executionStatus = FlushExecutionStatus.WORKER_FAILURE,
                        summaryMessage = "offline"
                    ),
                pendingQueueDepth = 1
            )

        assertThat(state).isInstanceOf(SyncUiState.RetryScheduled::class.java)
        assertThat((state as SyncUiState.RetryScheduled).attempt).isEqualTo(2)
    }

    @Test
    fun offlineConnectivityWinsOverMessageTextAndReportFailure() {
        val state =
            AutoFlushCoordinatorState().toSyncUiState(
                isOnline = false,
                latestFlushReport =
                    FlushReport(
                        executionStatus = FlushExecutionStatus.AUTH_EXPIRED,
                        summaryMessage = "The server said offline"
                    ),
                pendingQueueDepth = 0
            )

        assertThat(state).isEqualTo(SyncUiState.Offline())
    }

    @Test
    fun authExpiredReportMapsToFailedWhenOnline() {
        val state =
            AutoFlushCoordinatorState().toSyncUiState(
                isOnline = true,
                latestFlushReport =
                    FlushReport(
                        executionStatus = FlushExecutionStatus.AUTH_EXPIRED,
                        authExpired = true,
                        summaryMessage = "Login required"
                    ),
                pendingQueueDepth = 0
            )

        assertThat(state).isInstanceOf(SyncUiState.Failed::class.java)
        assertThat((state as SyncUiState.Failed).defaultLabel).isEqualTo("Auth expired")
    }

    @Test
    fun completedFlushWithBacklogMapsToPartial() {
        val state =
            AutoFlushCoordinatorState().toSyncUiState(
                isOnline = true,
                latestFlushReport =
                    FlushReport(
                        executionStatus = FlushExecutionStatus.COMPLETED,
                        backlogRemaining = true,
                        retryableRemainingCount = 5,
                        uploadedCount = 7,
                        summaryMessage = "Some scans remain queued"
                    ),
                pendingQueueDepth = 2
            )

        assertThat(state).isInstanceOf(SyncUiState.Partial::class.java)
        assertThat((state as SyncUiState.Partial).backlogRemainingCount).isEqualTo(5)
    }

    @Test
    fun completedFlushWithoutBacklogMapsToSynced() {
        val state =
            AutoFlushCoordinatorState().toSyncUiState(
                isOnline = true,
                latestFlushReport =
                    FlushReport(
                        executionStatus = FlushExecutionStatus.COMPLETED,
                        backlogRemaining = false,
                        retryableRemainingCount = 0,
                        uploadedCount = 11,
                        summaryMessage = "Done"
                    ),
                pendingQueueDepth = 0
            )

        assertThat(state).isInstanceOf(SyncUiState.Synced::class.java)
        assertThat((state as SyncUiState.Synced).uploadedCount).isEqualTo(11)
    }

    @Test
    fun messageTextDoesNotDriveOfflineProjectionWhenConnectivityIsKnown() {
        val state =
            AutoFlushCoordinatorState().toSyncUiState(
                isOnline = true,
                latestFlushReport =
                    FlushReport(
                        executionStatus = FlushExecutionStatus.WORKER_FAILURE,
                        summaryMessage = "offline"
                    ),
                pendingQueueDepth = 0
            )

        assertThat(state).isInstanceOf(SyncUiState.Failed::class.java)
        assertThat(state).isNotEqualTo(SyncUiState.Offline())
    }
}
