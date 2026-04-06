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
import za.co.voelgoed.fastcheck.feature.queue.QueueUiState
import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerSourceType
import za.co.voelgoed.fastcheck.feature.scanning.ui.ScanningUiState
import za.co.voelgoed.fastcheck.feature.scanning.ui.model.CaptureFeedbackState
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

        return ScanDestinationUiState(
            scannerStatusChip = scannerStatusChip,
            scannerStatusMessage = scanningUiState.scannerStatus,
            attendeeStatusChip = attendeeStatus.first,
            attendeeStatusMessage = attendeeStatus.second,
            showCameraPreview =
                scanningUiState.activeSourceType == ScannerSourceType.CAMERA &&
                    scanningUiState.isPreviewVisible,
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
            retryUploadVisible = shouldShowRetryUpload(queueUiState.localQueueDepth, uploadState)
        )
    }

    private fun scannerChipFor(uiState: ScanningUiState): StatusChipUiModel =
        when (val sessionState = uiState.sessionState) {
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
                    text = "Preparing attendee list",
                    tone = StatusTone.Info
                ) to "Loading attendees for this event before scan confidence improves."

            BootstrapSyncStatus.Failed ->
                StatusChipUiModel(
                    text = "Attendee list unavailable",
                    tone = StatusTone.Warning
                ) to "Scanning can continue, but attendee readiness is degraded until attendee data loads."

            BootstrapSyncStatus.Succeeded,
            BootstrapSyncStatus.Idle ->
                StatusChipUiModel(
                    text = "Attendee list unavailable",
                    tone = StatusTone.Warning
                ) to "No attendee cache is available for this event yet."
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

            uiState.sessionState == ScannerSessionState.Armed ->
                BannerUiModel(
                    title = "Preparing camera",
                    message = "The scan surface is active and the camera is getting ready.",
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

        if (currentEventSyncStatus == null && syncUiState.bootstrapStatus == BootstrapSyncStatus.Failed) {
            return BannerUiModel(
                title = "Attendee list still unavailable",
                message = "No attendee cache is available for this event yet. Scanner readiness and attendee readiness are separate until sync completes.",
                tone = StatusTone.Warning
            )
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

    private fun shouldShowRetryUpload(
        queueDepth: Int,
        uploadState: SyncUiState
    ): Boolean {
        if (queueDepth <= 0) return false

        return when (uploadState) {
            is SyncUiState.Partial -> true
            is SyncUiState.RetryScheduled -> true
            is SyncUiState.Failed -> uploadState.reason != "Auth expired"
            is SyncUiState.Offline -> false
            else -> false
        }
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
