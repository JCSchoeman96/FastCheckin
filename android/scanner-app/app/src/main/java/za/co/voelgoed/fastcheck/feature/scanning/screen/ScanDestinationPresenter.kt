package za.co.voelgoed.fastcheck.feature.scanning.screen

import java.time.Clock
import java.time.Duration
import java.time.Instant
import za.co.voelgoed.fastcheck.app.scanning.ScannerBlockReason
import za.co.voelgoed.fastcheck.app.scanning.ScannerSessionState
import za.co.voelgoed.fastcheck.core.designsystem.semantic.ScanUiState
import za.co.voelgoed.fastcheck.core.designsystem.semantic.StatusTone
import za.co.voelgoed.fastcheck.core.designsystem.semantic.SyncUiState
import za.co.voelgoed.fastcheck.domain.model.AttendeeSyncStatus
import za.co.voelgoed.fastcheck.feature.queue.QueueUploadRecoveryVisibility
import za.co.voelgoed.fastcheck.feature.queue.QueueUiState
import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerSourceType
import za.co.voelgoed.fastcheck.feature.scanning.screen.model.ScanOperatorAction
import za.co.voelgoed.fastcheck.feature.scanning.ui.ScanningUiState
import za.co.voelgoed.fastcheck.feature.scanning.ui.model.CaptureFeedbackState
import za.co.voelgoed.fastcheck.feature.scanning.ui.model.ScannerRecoveryState
import za.co.voelgoed.fastcheck.feature.sync.BootstrapSyncStatus
import za.co.voelgoed.fastcheck.feature.sync.SyncScreenUiState

class ScanDestinationPresenter(
    private val clock: Clock = Clock.systemUTC()
) {
    fun present(
        scanningUiState: ScanningUiState,
        queueUiState: QueueUiState,
        syncUiState: SyncScreenUiState,
        currentEventSyncStatus: AttendeeSyncStatus?
    ): ScanDestinationUiState {
        val scannerStatusChip = scannerChipFor(scanningUiState)
        val attendeeStatus = attendeeStatusFor(syncUiState, currentEventSyncStatus)
        val uploadState = queueUiState.uploadSemanticState
        val primaryRecoveryAction = primaryRecoveryActionFor(scanningUiState)

        return ScanDestinationUiState(
            scannerStatusChip = scannerStatusChip,
            scannerStatusMessage = scanningUiState.scannerStatus,
            attendeeStatusChip = attendeeStatus.first,
            attendeeStatusMessage = attendeeStatus.second,
            showCameraPreview = scanningUiState.shouldHostPreviewSurface,
            primaryRecoveryAction = primaryRecoveryAction?.first,
            primaryRecoveryActionLabel = primaryRecoveryAction?.second,
            previewBanner = previewBannerFor(scanningUiState),
            captureBanner = captureBannerFor(scanningUiState.lastCaptureFeedback),
            healthBanner =
                healthBannerFor(
                    queueUiState = queueUiState,
                    syncUiState = syncUiState,
                    currentEventSyncStatus = currentEventSyncStatus
                ),
            queueDepthLabel = queueDepthLabel(queueUiState.localQueueDepth),
            uploadStateLabel = uploadState.defaultLabel,
            manualSyncVisible = !syncUiState.isSyncing,
            retryUploadVisible =
                QueueUploadRecoveryVisibility.shouldShowRetryUpload(
                    queueUiState.localQueueDepth,
                    uploadState
                ),
            reloginVisible = requiresRelogin(queueUiState)
        )
    }

    private fun primaryRecoveryActionFor(
        uiState: ScanningUiState
    ): Pair<ScanOperatorAction, String>? =
        when (uiState.scannerRecoveryState) {
            is ScannerRecoveryState.RequestPermission ->
                ScanOperatorAction.RequestCameraAccess to "Allow camera access"

            ScannerRecoveryState.OpenSystemSettings ->
                ScanOperatorAction.OpenAppSettings to "Open app settings"

            is ScannerRecoveryState.SourceError ->
                if (uiState.activeSourceType == ScannerSourceType.CAMERA) {
                    ScanOperatorAction.ReconnectCamera to "Reconnect camera"
                } else {
                    null
                }

            ScannerRecoveryState.Starting,
            ScannerRecoveryState.Ready,
            ScannerRecoveryState.CameraNotRequired ->
                null
        }

    private fun requiresRelogin(queueUiState: QueueUiState): Boolean =
        queueUiState.localQueueDepth > 0 &&
            (queueUiState.uploadSemanticState as? SyncUiState.Failed)?.reason == "Auth expired"

    private fun scannerChipFor(uiState: ScanningUiState): StatusChipUiModel {
        if (
            uiState.activeSourceType == ScannerSourceType.CAMERA &&
            uiState.scannerRecoveryState == ScannerRecoveryState.Starting
        ) {
            return StatusChipUiModel(text = "Scanner starting", tone = StatusTone.Info)
        }

        return when (val sessionState = uiState.sessionState) {
            ScannerSessionState.Active ->
                StatusChipUiModel(text = "Scanner active", tone = StatusTone.Brand)

            ScannerSessionState.Armed ->
                StatusChipUiModel(text = "Scanner ready", tone = StatusTone.Neutral)

            ScannerSessionState.Idle ->
                StatusChipUiModel(text = "Scanner idle", tone = StatusTone.Muted)

            is ScannerSessionState.Blocked ->
                when (sessionState.reason) {
                    ScannerBlockReason.PermissionDenied ->
                        StatusChipUiModel(text = "Permission needed", tone = StatusTone.Warning)

                    ScannerBlockReason.SourceError ->
                        StatusChipUiModel(text = "Scanner blocked", tone = StatusTone.Destructive)

                    ScannerBlockReason.Backgrounded ->
                        StatusChipUiModel(text = "Scanner paused", tone = StatusTone.Muted)

                    ScannerBlockReason.PreviewUnavailable ->
                        StatusChipUiModel(text = "Preparing preview", tone = StatusTone.Info)

                    ScannerBlockReason.NotAuthenticated ->
                        StatusChipUiModel(text = "Scanner idle", tone = StatusTone.Muted)
                }
        }
    }

    private fun attendeeStatusFor(
        syncUiState: SyncScreenUiState,
        currentEventSyncStatus: AttendeeSyncStatus?
    ): Pair<StatusChipUiModel, String> {
        if (currentEventSyncStatus != null) {
            return if (isStale(currentEventSyncStatus)) {
                StatusChipUiModel(
                    text = "Attendee list may be old",
                    tone = StatusTone.Warning
                ) to "Using cached attendee data from ${currentEventSyncStatus.lastSuccessfulSyncAt ?: "an earlier sync"}."
            } else {
                StatusChipUiModel(
                    text = "Attendee list ready",
                    tone = StatusTone.Success
                ) to "Using ${currentEventSyncStatus.attendeeCount} attendees from the latest local sync."
            }
        }

        return when (syncUiState.bootstrapStatus) {
            BootstrapSyncStatus.Syncing ->
                StatusChipUiModel(
                    text = "Syncing attendee list",
                    tone = StatusTone.Info
                ) to "Preparing the attendee list for this event. This device is not ready for trusted green admission until sync completes."

            BootstrapSyncStatus.Failed ->
                StatusChipUiModel(
                    text = "Sync failed - retry required",
                    tone = StatusTone.Destructive
                ) to "Attendee sync failed for this event. Retry sync before trusting green admission on this device."

            BootstrapSyncStatus.Succeeded,
            BootstrapSyncStatus.Idle ->
                StatusChipUiModel(
                    text = "Attendee list not ready",
                    tone = StatusTone.Warning
                ) to "A trusted attendee cache is not available for this event yet. This device is not ready for trusted green admission."
        }
    }

    private fun previewBannerFor(uiState: ScanningUiState): BannerUiModel? =
        when {
            uiState.activeSourceType != ScannerSourceType.CAMERA ->
                BannerUiModel(
                    title = "Camera preview not in use",
                    message = "The active Zebra DataWedge source does not use the smartphone camera preview.",
                    tone = StatusTone.Neutral
                )

            uiState.isPreviewVisible ->
                null

            uiState.sessionState is ScannerSessionState.Blocked &&
                uiState.sessionState.reason == ScannerBlockReason.PermissionDenied ->
                BannerUiModel(
                    title = "Camera permission required",
                    message = "Allow camera access to start smartphone scanning on this device.",
                    tone = StatusTone.Warning
                )

            uiState.sessionState is ScannerSessionState.Blocked &&
                uiState.sessionState.reason == ScannerBlockReason.SourceError ->
                BannerUiModel(
                    title = "Scanner unavailable",
                    message = uiState.scannerStatus,
                    tone = StatusTone.Destructive
                )

            uiState.scannerRecoveryState == ScannerRecoveryState.Starting ->
                BannerUiModel(
                    title = "Preparing camera",
                    message = uiState.scannerStatus,
                    tone = StatusTone.Info
                )

            uiState.scannerRecoveryState == ScannerRecoveryState.Ready && !uiState.isPreviewVisible ->
                BannerUiModel(
                    title = "Scanner ready",
                    message = uiState.scannerStatus,
                    tone = StatusTone.Info
                )

            else ->
                null
        }

    private fun captureBannerFor(feedback: CaptureFeedbackState?): BannerUiModel? =
        when (feedback) {
            is CaptureFeedbackState.Success ->
                BannerUiModel(
                    message = feedback.message,
                    tone = StatusTone.Success,
                    title = feedback.title
                )

            is CaptureFeedbackState.Warning ->
                BannerUiModel(
                    message = feedback.message,
                    tone = StatusTone.Warning,
                    title = feedback.title
                )

            is CaptureFeedbackState.Error ->
                BannerUiModel(
                    message = feedback.message,
                    tone = StatusTone.Destructive,
                    title = feedback.title
                )

            null -> null
        }

    private fun healthBannerFor(
        queueUiState: QueueUiState,
        syncUiState: SyncScreenUiState,
        currentEventSyncStatus: AttendeeSyncStatus?
    ): BannerUiModel? {
        val uploadState = queueUiState.uploadSemanticState

        if (currentEventSyncStatus == null) {
            return when (syncUiState.bootstrapStatus) {
                BootstrapSyncStatus.Syncing ->
                    BannerUiModel(
                        title = "Syncing attendee list",
                        message = "Preparing the attendee cache for this event. The device is not ready for trusted green admission until sync completes.",
                        tone = StatusTone.Info
                    )

                BootstrapSyncStatus.Failed ->
                    BannerUiModel(
                        title = "Sync failed - retry required",
                        message =
                            syncUiState.errorMessage
                                ?.takeIf { it.isNotBlank() }
                                ?.let { "$it Retry attendee sync before using this device for trusted green admission." }
                                ?: "Attendee sync failed for this event. Retry attendee sync before using this device for trusted green admission.",
                        tone = StatusTone.Destructive
                    )

                BootstrapSyncStatus.Idle,
                BootstrapSyncStatus.Succeeded ->
                    BannerUiModel(
                        title = "Attendee sync required",
                        message = "This event does not have a trusted attendee cache yet. Complete attendee sync before relying on green admission on this device.",
                        tone = StatusTone.Warning
                    )
            }
        }

        if (uploadState is SyncUiState.Offline && queueUiState.localQueueDepth > 0) {
            return BannerUiModel(
                title = "Uploads paused offline",
                message = "${queueDepthLabel(queueUiState.localQueueDepth)} will upload automatically when the device reconnects.",
                tone = StatusTone.Offline
            )
        }

        if (uploadState is SyncUiState.Failed && uploadState.reason == "Auth expired") {
            return BannerUiModel(
                title = "Re-login required",
                message = "${queueDepthLabel(queueUiState.localQueueDepth)} cannot upload until the operator signs in again.",
                tone = StatusTone.Destructive
            )
        }

        return null
    }

    private fun queueDepthLabel(queueDepth: Int): String =
        when (queueDepth) {
            0 -> "No scans queued locally"
            1 -> "1 scan queued locally"
            else -> "$queueDepth scans queued locally"
        }

    private fun isStale(syncStatus: AttendeeSyncStatus): Boolean {
        val timestamp = syncStatus.lastSuccessfulSyncAt ?: return false
        val syncedAt =
            runCatching { Instant.parse(timestamp) }
                .getOrNull()
                ?: return false

        return Duration.between(syncedAt, clock.instant()) > STALE_SYNC_THRESHOLD
    }

    private companion object {
        val STALE_SYNC_THRESHOLD: Duration = Duration.ofMinutes(30)
    }
}
