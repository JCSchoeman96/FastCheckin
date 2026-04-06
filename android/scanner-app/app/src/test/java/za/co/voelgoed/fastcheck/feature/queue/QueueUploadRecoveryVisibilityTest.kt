package za.co.voelgoed.fastcheck.feature.queue

import com.google.common.truth.Truth.assertThat
import org.junit.Test
import za.co.voelgoed.fastcheck.core.designsystem.semantic.SyncUiState

class QueueUploadRecoveryVisibilityTest {
    @Test
    fun retryHiddenForAuthExpired() {
        assertThat(
            QueueUploadRecoveryVisibility.shouldShowRetryUpload(
                queueDepth = 2,
                uploadState = SyncUiState.Failed(reason = "Auth expired")
            )
        ).isFalse()
    }

    @Test
    fun retryHiddenOffline() {
        assertThat(
            QueueUploadRecoveryVisibility.shouldShowRetryUpload(
                queueDepth = 2,
                uploadState = SyncUiState.Offline()
            )
        ).isFalse()
    }

    @Test
    fun retryShownForPartial() {
        assertThat(
            QueueUploadRecoveryVisibility.shouldShowRetryUpload(
                queueDepth = 1,
                uploadState = SyncUiState.Partial(backlogRemainingCount = 1)
            )
        ).isTrue()
    }
}
