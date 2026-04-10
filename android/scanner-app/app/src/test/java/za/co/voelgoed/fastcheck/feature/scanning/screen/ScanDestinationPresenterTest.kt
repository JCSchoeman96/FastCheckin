package za.co.voelgoed.fastcheck.feature.scanning.screen

import com.google.common.truth.Truth.assertThat
import java.time.Clock
import java.time.Instant
import java.time.ZoneOffset
import org.junit.Test
import za.co.voelgoed.fastcheck.app.scanning.ScannerBlockReason
import za.co.voelgoed.fastcheck.app.scanning.ScannerSessionState
import za.co.voelgoed.fastcheck.core.designsystem.semantic.StatusTone
import za.co.voelgoed.fastcheck.core.designsystem.semantic.SyncUiState
import za.co.voelgoed.fastcheck.domain.model.AttendeeSyncStatus
import za.co.voelgoed.fastcheck.feature.queue.QueueUiState
import za.co.voelgoed.fastcheck.feature.scanning.domain.CameraPermissionState
import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerSourceType
import za.co.voelgoed.fastcheck.feature.scanning.screen.model.ScanOperatorAction
import za.co.voelgoed.fastcheck.feature.scanning.ui.ScanningUiState
import za.co.voelgoed.fastcheck.feature.scanning.ui.model.CaptureFeedbackState
import za.co.voelgoed.fastcheck.feature.scanning.ui.model.ScannerRecoveryState
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
        assertThat(uiState.attendeeStatusChip.text).isEqualTo("Sync failed - retry required")
        assertThat(uiState.attendeeStatusMessage).contains("Retry sync before trusting green admission")
        assertThat(uiState.healthBanner?.title).isEqualTo("Sync failed - retry required")
        assertThat(uiState.healthBanner?.message).contains("trusted green admission")
    }

    @Test
    fun bootstrapSyncingShowsNotReadyMessaging() {
        val uiState =
            presenter.present(
                scanningUiState = ScanningUiState(sessionState = ScannerSessionState.Active),
                queueUiState = QueueUiState(),
                syncUiState = SyncScreenUiState(bootstrapStatus = BootstrapSyncStatus.Syncing),
                currentEventSyncStatus = null
            )

        assertThat(uiState.attendeeStatusChip.text).isEqualTo("Syncing attendee list")
        assertThat(uiState.attendeeStatusMessage).contains("not ready for trusted green admission")
        assertThat(uiState.healthBanner?.title).isEqualTo("Syncing attendee list")
        assertThat(uiState.healthBanner?.message).contains("not ready for trusted green admission")
    }

    @Test
    fun trustedSyncedEventShowsReadyState() {
        val uiState =
            presenter.present(
                scanningUiState = ScanningUiState(sessionState = ScannerSessionState.Active),
                queueUiState = QueueUiState(),
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

        assertThat(uiState.attendeeStatusChip.text).isEqualTo("Attendee list ready")
        assertThat(uiState.attendeeStatusMessage).contains("latest local sync")
        assertThat(uiState.healthBanner).isNull()
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
        assertThat(uiState.manualSyncVisible).isTrue()
        assertThat(uiState.reloginVisible).isFalse()
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
        assertThat(uiState.reloginVisible).isTrue()
        assertThat(uiState.retryUploadVisible).isFalse()
    }

    @Test
    fun manualSyncHiddenWhileSyncRunning() {
        val uiState =
            presenter.present(
                scanningUiState = ScanningUiState(sessionState = ScannerSessionState.Active),
                queueUiState = QueueUiState(),
                syncUiState = SyncScreenUiState(isSyncing = true, bootstrapStatus = BootstrapSyncStatus.Succeeded),
                currentEventSyncStatus =
                    AttendeeSyncStatus(
                        eventId = 5,
                        lastServerTime = "2026-03-13T08:50:00Z",
                        lastSuccessfulSyncAt = "2026-03-13T08:50:00Z",
                        syncType = "full",
                        attendeeCount = 20
                    )
            )

        assertThat(uiState.manualSyncVisible).isFalse()
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
                        lastCaptureFeedback =
                            CaptureFeedbackState.Success(
                                title = "Queued locally",
                                message = "Queued locally (pending upload)"
                            )
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

    @Test
    fun requestPermissionShowsAllowCameraAccessAction() {
        val uiState =
            presenter.present(
                scanningUiState =
                    ScanningUiState(
                        scannerRecoveryState = ScannerRecoveryState.RequestPermission(false)
                    ),
                queueUiState = QueueUiState(),
                syncUiState = SyncScreenUiState(),
                currentEventSyncStatus = null
            )

        assertThat(uiState.primaryRecoveryAction).isEqualTo(ScanOperatorAction.RequestCameraAccess)
        assertThat(uiState.primaryRecoveryActionLabel).isEqualTo("Allow camera access")
    }

    @Test
    fun openSystemSettingsShowsSettingsAction() {
        val uiState =
            presenter.present(
                scanningUiState =
                    ScanningUiState(
                        scannerRecoveryState = ScannerRecoveryState.OpenSystemSettings
                    ),
                queueUiState = QueueUiState(),
                syncUiState = SyncScreenUiState(),
                currentEventSyncStatus = null
            )

        assertThat(uiState.primaryRecoveryAction).isEqualTo(ScanOperatorAction.OpenAppSettings)
        assertThat(uiState.primaryRecoveryActionLabel).isEqualTo("Open app settings")
    }

    @Test
    fun cameraSourceErrorShowsReconnectAction() {
        val uiState =
            presenter.present(
                scanningUiState =
                    ScanningUiState(
                        activeSourceType = ScannerSourceType.CAMERA,
                        scannerRecoveryState = ScannerRecoveryState.SourceError("camera unavailable")
                    ),
                queueUiState = QueueUiState(),
                syncUiState = SyncScreenUiState(),
                currentEventSyncStatus = null
            )

        assertThat(uiState.primaryRecoveryAction).isEqualTo(ScanOperatorAction.ReconnectCamera)
        assertThat(uiState.primaryRecoveryActionLabel).isEqualTo("Reconnect camera")
    }

    @Test
    fun cameraNotRequiredShowsNoCameraRecoveryAction() {
        val uiState =
            presenter.present(
                scanningUiState =
                    ScanningUiState(
                        activeSourceType = ScannerSourceType.BROADCAST_INTENT,
                        scannerRecoveryState = ScannerRecoveryState.CameraNotRequired
                    ),
                queueUiState = QueueUiState(),
                syncUiState = SyncScreenUiState(),
                currentEventSyncStatus = null
            )

        assertThat(uiState.primaryRecoveryAction).isNull()
        assertThat(uiState.primaryRecoveryActionLabel).isNull()
    }

    @Test
    fun readyRecoveryShowsNoAction() {
        val uiState =
            presenter.present(
                scanningUiState =
                    ScanningUiState(
                        scannerRecoveryState = ScannerRecoveryState.Ready
                    ),
                queueUiState = QueueUiState(),
                syncUiState = SyncScreenUiState(),
                currentEventSyncStatus = null
            )

        assertThat(uiState.primaryRecoveryAction).isNull()
        assertThat(uiState.primaryRecoveryActionLabel).isNull()
    }

    @Test
    fun startingRecoveryShowsPreparingStateNotReady() {
        val uiState =
            presenter.present(
                scanningUiState =
                    ScanningUiState(
                        activeSourceType = ScannerSourceType.CAMERA,
                        cameraPermissionState = CameraPermissionState.GRANTED,
                        scannerRecoveryState = ScannerRecoveryState.Starting,
                        sessionState = ScannerSessionState.Blocked(
                            za.co.voelgoed.fastcheck.app.scanning.ScannerBlockReason.PreviewUnavailable
                        ),
                        scannerStatus = "Preparing scanner input source"
                    ),
                queueUiState = QueueUiState(),
                syncUiState = SyncScreenUiState(),
                currentEventSyncStatus = null
            )

        assertThat(uiState.scannerStatusChip.text).isNotEqualTo("Scanner ready")
        assertThat(uiState.previewBanner?.tone).isEqualTo(StatusTone.Info)
        assertThat(uiState.previewBanner?.message).isEqualTo("Preparing scanner input source")
    }

    @Test
    fun showCameraPreviewFollowsSharedShouldHostPreviewSurface() {
        val hostingUiState =
            presenter.present(
                scanningUiState =
                    ScanningUiState(
                        activeSourceType = ScannerSourceType.CAMERA,
                        cameraPermissionState = CameraPermissionState.GRANTED,
                        shouldHostPreviewSurface = true,
                        scannerRecoveryState = ScannerRecoveryState.Starting
                    ),
                queueUiState = QueueUiState(),
                syncUiState = SyncScreenUiState(),
                currentEventSyncStatus = null
            )
        val nonHostingUiState =
            presenter.present(
                scanningUiState =
                    ScanningUiState(
                        activeSourceType = ScannerSourceType.CAMERA,
                        cameraPermissionState = CameraPermissionState.GRANTED,
                        shouldHostPreviewSurface = false,
                        scannerRecoveryState = ScannerRecoveryState.Starting
                    ),
                queueUiState = QueueUiState(),
                syncUiState = SyncScreenUiState(),
                currentEventSyncStatus = null
            )

        assertThat(hostingUiState.showCameraPreview).isTrue()
        assertThat(nonHostingUiState.showCameraPreview).isFalse()
    }

    @Test
    fun previewNotVisibleChipIsDistinctFromPreviewUnavailable() {
        val notVisibleUiState =
            presenter.present(
                scanningUiState =
                    ScanningUiState(
                        activeSourceType = ScannerSourceType.CAMERA,
                        cameraPermissionState = CameraPermissionState.GRANTED,
                        sessionState = ScannerSessionState.Blocked(ScannerBlockReason.PreviewNotVisible),
                        scannerRecoveryState = ScannerRecoveryState.Starting,
                        shouldHostPreviewSurface = true,
                        scannerStatus = "Camera preview is becoming visible. Scanner will start automatically."
                    ),
                queueUiState = QueueUiState(),
                syncUiState = SyncScreenUiState(),
                currentEventSyncStatus = null
            )

        val unavailableUiState =
            presenter.present(
                scanningUiState =
                    ScanningUiState(
                        activeSourceType = ScannerSourceType.CAMERA,
                        cameraPermissionState = CameraPermissionState.GRANTED,
                        sessionState = ScannerSessionState.Blocked(ScannerBlockReason.PreviewUnavailable),
                        scannerRecoveryState = ScannerRecoveryState.Starting,
                        shouldHostPreviewSurface = true,
                        scannerStatus = "Preparing the scan preview before camera scanning can start."
                    ),
                queueUiState = QueueUiState(),
                syncUiState = SyncScreenUiState(),
                currentEventSyncStatus = null
            )

        assertThat(notVisibleUiState.scannerStatusChip.text).isEqualTo("Preview loading")
        assertThat(notVisibleUiState.scannerStatusChip.tone).isEqualTo(StatusTone.Info)
        assertThat(unavailableUiState.scannerStatusChip.text).isEqualTo("Preparing preview")
        assertThat(unavailableUiState.scannerStatusChip.tone).isEqualTo(StatusTone.Info)
        assertThat(notVisibleUiState.scannerStatusChip.text)
            .isNotEqualTo(unavailableUiState.scannerStatusChip.text)
    }

    @Test
    fun previewNotVisibleDoesNotShowRecoveryAction() {
        val uiState =
            presenter.present(
                scanningUiState =
                    ScanningUiState(
                        activeSourceType = ScannerSourceType.CAMERA,
                        cameraPermissionState = CameraPermissionState.GRANTED,
                        sessionState = ScannerSessionState.Blocked(ScannerBlockReason.PreviewNotVisible),
                        scannerRecoveryState = ScannerRecoveryState.Starting,
                        shouldHostPreviewSurface = true,
                        scannerStatus = "Camera preview is becoming visible. Scanner will start automatically."
                    ),
                queueUiState = QueueUiState(),
                syncUiState = SyncScreenUiState(),
                currentEventSyncStatus = null
            )

        assertThat(uiState.primaryRecoveryAction).isNull()
        assertThat(uiState.primaryRecoveryActionLabel).isNull()
    }

    @Test
    fun readyWithInvisiblePreviewUsesTruthfulInformationalCopy() {
        val uiState =
            presenter.present(
                scanningUiState =
                    ScanningUiState(
                        activeSourceType = ScannerSourceType.CAMERA,
                        scannerRecoveryState = ScannerRecoveryState.Ready,
                        shouldHostPreviewSurface = true,
                        isSourceReady = true,
                        isPreviewVisible = false,
                        scannerStatus = "Scanner ready. Preview is still becoming visible in the UI."
                    ),
                queueUiState = QueueUiState(),
                syncUiState = SyncScreenUiState(),
                currentEventSyncStatus = null
            )

        assertThat(uiState.showCameraPreview).isTrue()
        assertThat(uiState.previewBanner?.title).isEqualTo("Scanner ready")
        assertThat(uiState.previewBanner?.message)
            .isEqualTo("Scanner ready. Preview is still becoming visible in the UI.")
    }
}
