package za.co.voelgoed.fastcheck.feature.scanning.screen

import com.google.common.truth.Truth.assertThat
import java.time.Clock
import java.time.Instant
import java.time.ZoneOffset
import org.junit.Test
import za.co.voelgoed.fastcheck.app.scanning.ScannerSessionState
import za.co.voelgoed.fastcheck.core.designsystem.semantic.StatusTone
import za.co.voelgoed.fastcheck.core.designsystem.semantic.SyncUiState
import za.co.voelgoed.fastcheck.domain.model.AttendeeSyncStatus
import za.co.voelgoed.fastcheck.feature.queue.QueueUiState
import za.co.voelgoed.fastcheck.feature.scanning.ui.ScanningUiState
import za.co.voelgoed.fastcheck.feature.scanning.ui.model.CaptureFeedbackState
import za.co.voelgoed.fastcheck.feature.sync.BootstrapSyncStatus
import za.co.voelgoed.fastcheck.feature.sync.SyncScreenUiState

class ScanDestinationPresenterTest {
    private val presenter =
        ScanDestinationPresenter(
            clock = Clock.fixed(Instant.parse("2026-03-13T09:00:00Z"), ZoneOffset.UTC)
        )

    @Test
    fun scannerAndAttendeeReadinessStaySeparate() {
        val uiState =
            presenter.present(
                scanningUiState =
                    ScanningUiState(
                        sessionState = ScannerSessionState.Active,
                        scannerStatus = "Scanner ready.",
                        isPreviewVisible = true
                    ),
                queueUiState = QueueUiState(),
                syncUiState =
                    SyncScreenUiState(
                        bootstrapStatus = BootstrapSyncStatus.Failed,
                        errorMessage = "Timeout"
                    ),
                currentEventSyncStatus = null
            )

        assertThat(uiState.scannerStatusChip.text).isEqualTo("Scanner active")
        assertThat(uiState.attendeeStatusChip.text).isEqualTo("Attendee list unavailable")
    }

    @Test
    fun offlineBacklogShowsWarningWithoutRetryAction() {
        val uiState =
            presenter.present(
                scanningUiState = ScanningUiState(sessionState = ScannerSessionState.Active),
                queueUiState =
                    QueueUiState(
                        localQueueDepth = 3,
                        uploadSemanticState = SyncUiState.Offline()
                    ),
                syncUiState = SyncScreenUiState(bootstrapStatus = BootstrapSyncStatus.Succeeded),
                currentEventSyncStatus =
                    AttendeeSyncStatus(
                        eventId = 5,
                        lastServerTime = "2026-03-13T08:50:00Z",
                        lastSuccessfulSyncAt = "2026-03-13T08:50:00Z",
                        syncType = "full",
                        attendeeCount = 20
                    )
            )

        assertThat(uiState.healthBanner?.tone).isEqualTo(StatusTone.Offline)
        assertThat(uiState.retryUploadVisible).isFalse()
    }

    @Test
    fun authExpiredShowsDestructiveHealthBanner() {
        val uiState =
            presenter.present(
                scanningUiState = ScanningUiState(sessionState = ScannerSessionState.Active),
                queueUiState =
                    QueueUiState(
                        localQueueDepth = 2,
                        uploadSemanticState = SyncUiState.Failed(reason = "Auth expired")
                    ),
                syncUiState = SyncScreenUiState(),
                currentEventSyncStatus =
                    AttendeeSyncStatus(
                        eventId = 5,
                        lastServerTime = "2026-03-13T08:50:00Z",
                        lastSuccessfulSyncAt = "2026-03-13T08:50:00Z",
                        syncType = "full",
                        attendeeCount = 20
                    )
            )

        assertThat(uiState.healthBanner?.tone).isEqualTo(StatusTone.Destructive)
    }

    @Test
    fun retryUploadShownOnlyForRecoverableBacklog() {
        val uiState =
            presenter.present(
                scanningUiState = ScanningUiState(sessionState = ScannerSessionState.Active),
                queueUiState =
                    QueueUiState(
                        localQueueDepth = 4,
                        uploadSemanticState = SyncUiState.Partial(backlogRemainingCount = 4)
                    ),
                syncUiState = SyncScreenUiState(),
                currentEventSyncStatus =
                    AttendeeSyncStatus(
                        eventId = 5,
                        lastServerTime = "2026-03-13T08:50:00Z",
                        lastSuccessfulSyncAt = "2026-03-13T08:50:00Z",
                        syncType = "full",
                        attendeeCount = 20
                    )
            )

        assertThat(uiState.retryUploadVisible).isTrue()
    }

    @Test
    fun queuedLocalFeedbackNeverClaimsServerAcceptance() {
        val uiState =
            presenter.present(
                scanningUiState =
                    ScanningUiState(
                        sessionState = ScannerSessionState.Active,
                        lastCaptureFeedback = CaptureFeedbackState.Success("Queued locally (pending upload)")
                    ),
                queueUiState = QueueUiState(),
                syncUiState = SyncScreenUiState(),
                currentEventSyncStatus =
                    AttendeeSyncStatus(
                        eventId = 5,
                        lastServerTime = "2026-03-13T08:50:00Z",
                        lastSuccessfulSyncAt = "2026-03-13T08:50:00Z",
                        syncType = "full",
                        attendeeCount = 20
                    )
            )

        assertThat(uiState.captureBanner?.message).contains("Queued locally")
        assertThat(uiState.captureBanner?.message).doesNotContain("Accepted by server")
    }
}
