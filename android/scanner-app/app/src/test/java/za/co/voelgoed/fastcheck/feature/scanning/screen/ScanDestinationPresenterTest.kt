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
import za.co.voelgoed.fastcheck.domain.model.ScannerSession
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
    fun lastSyncLabelsUseFriendlyOperatorFormatting() {
        val unknown = trustedSyncedUiState(lastSuccessfulSyncAt = null)
        val justNow = trustedSyncedUiState(lastSuccessfulSyncAt = "2026-03-13T08:59:30Z")
        val sameDay = trustedSyncedUiState(lastSuccessfulSyncAt = "2026-03-13T08:50:00Z")
        val older = trustedSyncedUiState(lastSuccessfulSyncAt = "2026-03-12T08:50:00Z")
        val invalid = trustedSyncedUiState(lastSuccessfulSyncAt = "not-a-timestamp")

        assertThat(unknown.scannerOverlaySyncLabel).isEqualTo("Last sync unknown")
        assertThat(justNow.scannerOverlaySyncLabel).isEqualTo("Last sync just now")
        assertThat(sameDay.scannerOverlaySyncLabel).isEqualTo("Last sync 08:50")
        assertThat(older.scannerOverlaySyncLabel).isEqualTo("Last sync 12 Mar 08:50")
        assertThat(invalid.scannerOverlaySyncLabel).isEqualTo("Last sync unknown")
    }

    @Test
    fun scannerAndAdmissionReadinessStaySeparate() {
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
        assertThat(uiState.admissionSectionTitle).isEqualTo("Admission readiness")
        assertThat(uiState.admissionStatusChip.text).isEqualTo("Sync failed")
        assertThat(uiState.admissionStatusVerdict).isEqualTo("Admission refresh failed")
        assertThat(uiState.admissionStatusDetail).isEqualTo("Use manual sync when connectivity is available.")
        assertThat(uiState.queueUploadSectionTitle).isEqualTo("Queue & upload")
        assertThat(uiState.queueUploadStatusChip.text).isEqualTo("No upload backlog")
        assertThat(uiState.queueUploadStatusVerdict).isEqualTo("Upload queue clear")
        assertThat(uiState.queueUploadStatusDetail)
            .isEqualTo("New scans will still be saved locally before upload.")
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

        assertThat(uiState.admissionStatusChip.text).isEqualTo("Syncing attendee list")
        assertThat(uiState.admissionStatusVerdict).isEqualTo("Preparing admission data")
        assertThat(uiState.admissionStatusDetail).isEqualTo("Attendees are syncing now.")
        assertThat(uiState.queueUploadStatusChip.text).isEqualTo("No upload backlog")
        assertThat(uiState.queueUploadStatusDetail).doesNotContain("trusted green admission")
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

        assertThat(uiState.admissionStatusChip.text).isEqualTo("Attendee list ready")
        assertThat(uiState.admissionStatusVerdict).isEqualTo("Admission state current")
        assertThat(uiState.admissionStatusDetail).isEqualTo("Recent attendee data is available for this event.")
        assertThat(uiState.scannerOverlayEventLabel).isEqualTo("Active Event: #5")
        assertThat(uiState.syncedAttendeeCountLabel).isEqualTo("Synced attendees: 20")
        assertThat(uiState.scannerOverlaySyncLabel).isEqualTo("Last sync 08:50")
        assertThat(uiState.queueUploadStatusChip.text).isEqualTo("No upload backlog")
    }

    @Test
    fun zeroSyncedAttendeesDoesNotOverrideReadyAdmissionState() {
        val uiState =
            presenter.present(
                scanningUiState = ScanningUiState(sessionState = ScannerSessionState.Active),
                queueUiState = QueueUiState(),
                syncUiState = SyncScreenUiState(bootstrapStatus = BootstrapSyncStatus.Succeeded),
                currentEventSyncStatus =
                    AttendeeSyncStatus(
                        eventId = 99,
                        lastServerTime = "2026-03-13T08:50:00Z",
                        lastSuccessfulSyncAt = "2026-03-13T08:50:00Z",
                        syncType = "full",
                        attendeeCount = 0
                    )
            )

        assertThat(uiState.admissionStatusChip.text).isEqualTo("Attendee cache current")
        assertThat(uiState.admissionStatusVerdict).isEqualTo("Admission state current")
        assertThat(uiState.admissionStatusDetail)
            .isEqualTo("The attendee cache is synced for this event and currently contains no attendees.")
        assertThat(uiState.scannerOverlayEventLabel).isEqualTo("Active Event: #99")
        assertThat(uiState.syncedAttendeeCountLabel).isEqualTo("Synced attendees: 0")
        assertThat(uiState.manualSyncVisible).isFalse()
    }

    @Test
    fun activeEventWithoutCacheShowsAdmissionDataMissing() {
        val uiState =
            presenter.present(
                scanningUiState = ScanningUiState(sessionState = ScannerSessionState.Active),
                queueUiState = QueueUiState(),
                syncUiState =
                    SyncScreenUiState(
                        bootstrapStatus = BootstrapSyncStatus.Idle,
                        bootstrapEventId = 5
                    ),
                currentEventSyncStatus = null
            )

        assertThat(uiState.scannerOverlayEventLabel).isEqualTo("Active Event: #5")
        assertThat(uiState.admissionStatusVerdict).isEqualTo("Admission data missing")
        assertThat(uiState.admissionStatusDetail).isEqualTo("Sync attendees before relying on scan decisions.")
        assertThat(uiState.manualSyncVisible).isTrue()
    }

    @Test
    fun noActiveEventShowsAdmissionUnavailable() {
        val uiState =
            presenter.present(
                scanningUiState = ScanningUiState(sessionState = ScannerSessionState.Active),
                queueUiState = QueueUiState(),
                syncUiState = SyncScreenUiState(bootstrapStatus = BootstrapSyncStatus.Idle),
                currentEventSyncStatus = null
            )

        assertThat(uiState.scannerOverlayEventLabel).isEqualTo("Active Event: unavailable")
        assertThat(uiState.admissionStatusVerdict).isEqualTo("Admission unavailable")
        assertThat(uiState.admissionStatusDetail).isEqualTo("Sign in to an event before scanning.")
        assertThat(uiState.manualSyncVisible).isFalse()
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

        assertThat(uiState.queueUploadStatusChip.text).isEqualTo("Uploads paused offline")
        assertThat(uiState.queueUploadStatusChip.tone).isEqualTo(StatusTone.Offline)
        assertThat(uiState.queueUploadStatusVerdict).isEqualTo("Queued scans waiting")
        assertThat(uiState.queueUploadStatusDetail)
            .isEqualTo("Uploads will retry automatically when connectivity returns.")
        assertThat(uiState.retryUploadVisible).isFalse()
        assertThat(uiState.manualSyncVisible).isFalse()
        assertThat(uiState.reloginVisible).isFalse()
    }

    @Test
    fun authExpiredShowsDestructiveQueueUploadStatus() {
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

        assertThat(uiState.queueUploadStatusChip.text).isEqualTo("Re-login required")
        assertThat(uiState.queueUploadStatusChip.tone).isEqualTo(StatusTone.Destructive)
        assertThat(uiState.queueUploadStatusVerdict).isEqualTo("Upload paused")
        assertThat(uiState.queueUploadStatusDetail)
            .isEqualTo("Sign in again to resume uploads for this event.")
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
    fun manualSyncIsRecoveryOnly() {
        val freshStatus =
            AttendeeSyncStatus(
                eventId = 5,
                lastServerTime = "2026-03-13T08:50:00Z",
                lastSuccessfulSyncAt = "2026-03-13T08:50:00Z",
                syncType = "full",
                attendeeCount = 20
            )
        val failedBootstrap =
            presenter.present(
                scanningUiState = ScanningUiState(sessionState = ScannerSessionState.Active),
                queueUiState = QueueUiState(),
                syncUiState =
                    SyncScreenUiState(
                        bootstrapStatus = BootstrapSyncStatus.Failed,
                        bootstrapEventId = 5,
                        errorMessage = "Timeout"
                    ),
                currentEventSyncStatus = null
            )
        val emptyCache =
            presenter.present(
                scanningUiState = ScanningUiState(sessionState = ScannerSessionState.Active),
                queueUiState = QueueUiState(),
                syncUiState = SyncScreenUiState(bootstrapStatus = BootstrapSyncStatus.Succeeded),
                currentEventSyncStatus = freshStatus.copy(attendeeCount = 0)
            )
        val staleCache =
            presenter.present(
                scanningUiState = ScanningUiState(sessionState = ScannerSessionState.Active),
                queueUiState = QueueUiState(),
                syncUiState = SyncScreenUiState(bootstrapStatus = BootstrapSyncStatus.Succeeded),
                currentEventSyncStatus = freshStatus.copy(lastSuccessfulSyncAt = "2026-03-13T08:00:00Z")
            )
        val healthyCache =
            presenter.present(
                scanningUiState = ScanningUiState(sessionState = ScannerSessionState.Active),
                queueUiState = QueueUiState(),
                syncUiState = SyncScreenUiState(bootstrapStatus = BootstrapSyncStatus.Succeeded),
                currentEventSyncStatus = freshStatus
            )
        val noActiveEvent =
            presenter.present(
                scanningUiState = ScanningUiState(sessionState = ScannerSessionState.Active),
                queueUiState = QueueUiState(),
                syncUiState = SyncScreenUiState(),
                currentEventSyncStatus = null
            )

        assertThat(failedBootstrap.manualSyncVisible).isTrue()
        assertThat(emptyCache.manualSyncVisible).isFalse()
        assertThat(staleCache.manualSyncVisible).isTrue()
        assertThat(healthyCache.manualSyncVisible).isFalse()
        assertThat(noActiveEvent.manualSyncVisible).isFalse()
    }

    @Test
    fun staleSyncedEventShowsRefreshVerdict() {
        val uiState =
            presenter.present(
                scanningUiState = ScanningUiState(sessionState = ScannerSessionState.Active),
                queueUiState = QueueUiState(),
                syncUiState = SyncScreenUiState(bootstrapStatus = BootstrapSyncStatus.Succeeded),
                currentEventSyncStatus =
                    AttendeeSyncStatus(
                        eventId = 5,
                        lastServerTime = "2026-03-13T08:00:00Z",
                        lastSuccessfulSyncAt = "2026-03-13T08:00:00Z",
                        syncType = "full",
                        attendeeCount = 20
                    )
            )

        assertThat(uiState.admissionStatusVerdict).isEqualTo("Admission needs a refresh")
        assertThat(uiState.admissionStatusDetail)
            .isEqualTo("Existing attendee data is available, but a sync should run before heavy scanning.")
    }

    @Test
    fun strugglingSyncedEventKeepsAdmissionUsableButDegraded() {
        val uiState =
            presenter.present(
                scanningUiState = ScanningUiState(sessionState = ScannerSessionState.Active),
                queueUiState = QueueUiState(),
                syncUiState = SyncScreenUiState(bootstrapStatus = BootstrapSyncStatus.Succeeded),
                currentEventSyncStatus =
                    AttendeeSyncStatus(
                        eventId = 5,
                        lastServerTime = "2026-03-13T08:00:00Z",
                        lastSuccessfulSyncAt = "2026-03-13T08:00:00Z",
                        syncType = "full",
                        attendeeCount = 20,
                        consecutiveFailures = 1
                    )
            )

        assertThat(uiState.admissionStatusChip.text).isEqualTo("Sync delayed")
        assertThat(uiState.admissionStatusVerdict).isEqualTo("Admission needs a refresh")
        assertThat(uiState.admissionStatusDetail)
            .isEqualTo("Sync is retrying in the background; saved attendee data is still available.")
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
        assertThat(uiState.queueUploadStatusVerdict).isEqualTo("Queued scans waiting")
    }

    @Test
    fun uploadFailureUsesVerdictAndDetail() {
        val uiState =
            presenter.present(
                scanningUiState = ScanningUiState(sessionState = ScannerSessionState.Active),
                queueUiState =
                    QueueUiState(
                        localQueueDepth = 4,
                        uploadSemanticState = SyncUiState.Failed(reason = "Network timeout")
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

        assertThat(uiState.queueUploadStatusChip.text).isEqualTo("Upload failed")
        assertThat(uiState.queueUploadStatusVerdict).isEqualTo("Upload needs attention")
        assertThat(uiState.queueUploadStatusDetail).isEqualTo("Retry upload when the network is available.")
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
        assertThat(uiState.scannerDiagnosticLabel).isEqualTo("Diagnostics")
        assertThat(uiState.scannerDiagnosticMessage).isEqualTo("Camera permission is required.")
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
    fun cameraSourceErrorShowsNoPrimaryRecoveryAction() {
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

        assertThat(uiState.primaryRecoveryAction).isNull()
        assertThat(uiState.primaryRecoveryActionLabel).isNull()
        assertThat(uiState.scannerDiagnosticLabel).isEqualTo("Diagnostics")
        assertThat(uiState.scannerDiagnosticMessage).contains("camera unavailable")
    }

    @Test
    fun stuckPreviewShowsRestartCameraAction() {
        val uiState =
            presenter.present(
                scanningUiState =
                    ScanningUiState(
                        activeSourceType = ScannerSourceType.CAMERA,
                        scannerRecoveryState = ScannerRecoveryState.StuckPreview,
                        scannerStatus = "Camera preview appears stuck. Restart camera to recover."
                    ),
                queueUiState = QueueUiState(),
                syncUiState = SyncScreenUiState(),
                currentEventSyncStatus = null
            )

        assertThat(uiState.primaryRecoveryAction).isEqualTo(ScanOperatorAction.ReconnectCamera)
        assertThat(uiState.primaryRecoveryActionLabel).isEqualTo("Restart camera")
        assertThat(uiState.scannerStatusChip.text).isEqualTo("Camera restart required")
        assertThat(uiState.previewBanner?.title).isEqualTo("Camera preview stuck")
        assertThat(uiState.scannerDiagnosticLabel).isEqualTo("Diagnostics")
        assertThat(uiState.scannerDiagnosticMessage).isEqualTo("Camera preview is not responding.")
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
        assertThat(uiState.scannerDiagnosticLabel).isNull()
        assertThat(uiState.scannerDiagnosticMessage).isNull()
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
        assertThat(uiState.scannerDiagnosticLabel).isEqualTo("Diagnostics")
        assertThat(uiState.scannerDiagnosticMessage).isEqualTo("Camera preview is still becoming visible.")
    }

    private fun trustedSyncedUiState(lastSuccessfulSyncAt: String?): ScanDestinationUiState =
        presenter.present(
            scanningUiState = ScanningUiState(sessionState = ScannerSessionState.Active),
            queueUiState = QueueUiState(),
            syncUiState = SyncScreenUiState(bootstrapStatus = BootstrapSyncStatus.Succeeded),
            currentEventSyncStatus =
                AttendeeSyncStatus(
                    eventId = 5,
                    lastServerTime = lastSuccessfulSyncAt,
                    lastSuccessfulSyncAt = lastSuccessfulSyncAt,
                    syncType = "full",
                    attendeeCount = 20
                )
        )

    @Test
    fun usesSessionEventNameWhenAvailable() {
        val uiState =
            presenter.present(
                session =
                    ScannerSession(
                        eventId = 123,
                        eventName = "Voelgoed Fees Conference Long Name",
                        expiresInSeconds = 3600,
                        authenticatedAtEpochMillis = 1L,
                        expiresAtEpochMillis = 2L
                    ),
                scanningUiState = ScanningUiState(sessionState = ScannerSessionState.Active),
                queueUiState = QueueUiState(),
                syncUiState = SyncScreenUiState(),
                currentEventSyncStatus = null
            )

        assertThat(uiState.scannerOverlayEventLabel)
            .isEqualTo("Active Event: Voelgoed Fees Conference Long Name")
    }

    @Test
    fun prefersSessionEventShortnameWhenAvailable() {
        val uiState =
            presenter.present(
                session =
                    ScannerSession(
                        eventId = 123,
                        eventName = "Voelgoed Fees Conference Long Name",
                        eventShortname = "VG Fees",
                        expiresInSeconds = 3600,
                        authenticatedAtEpochMillis = 1L,
                        expiresAtEpochMillis = 2L
                    ),
                scanningUiState = ScanningUiState(sessionState = ScannerSessionState.Active),
                queueUiState = QueueUiState(),
                syncUiState = SyncScreenUiState(),
                currentEventSyncStatus = null
            )

        assertThat(uiState.scannerOverlayEventLabel).isEqualTo("Active Event: VG Fees")
    }
}
