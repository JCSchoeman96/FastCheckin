package za.co.voelgoed.fastcheck.feature.scanning.screen

import java.time.Clock
import java.time.Duration
import java.time.Instant
import za.co.voelgoed.fastcheck.app.scanning.ScannerBlockReason
import za.co.voelgoed.fastcheck.app.scanning.ScannerSessionState
import za.co.voelgoed.fastcheck.core.designsystem.semantic.StatusTone
import za.co.voelgoed.fastcheck.core.designsystem.semantic.SyncUiState
import za.co.voelgoed.fastcheck.domain.model.AttendeeSyncStatus
import za.co.voelgoed.fastcheck.domain.policy.AdmissionRuntimePolicy
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
        val admissionStatus = admissionStatusFor(syncUiState, currentEventSyncStatus)
        val uploadState = queueUiState.uploadSemanticState
        val queueUploadStatus = queueUploadStatusFor(queueUiState)
        val primaryRecoveryAction = primaryRecoveryActionFor(scanningUiState)

        return ScanDestinationUiState(
            activeEventLabel = activeEventLabelFor(syncUiState, currentEventSyncStatus),
            syncedAttendeeCountLabel = syncedAttendeeCountLabelFor(currentEventSyncStatus),
            lastSyncLabel = lastSyncLabelFor(currentEventSyncStatus),
            scannerStatusChip = scannerStatusChip,
            scannerStatusMessage = scanningUiState.scannerStatus,
            scannerDiagnosticMessage = scanningUiState.scannerDebugStatus,
            admissionSectionTitle = ADMISSION_SECTION_TITLE,
            admissionStatusChip = admissionStatus.first,
            admissionStatusMessage = admissionStatus.second,
            showCameraPreview = scanningUiState.shouldHostPreviewSurface,
            primaryRecoveryAction = primaryRecoveryAction?.first,
            primaryRecoveryActionLabel = primaryRecoveryAction?.second,
            previewBanner = previewBannerFor(scanningUiState),
            captureBanner = captureBannerFor(scanningUiState.lastCaptureFeedback),
            queueUploadSectionTitle = QUEUE_UPLOAD_SECTION_TITLE,
            queueDepthLabel = queueDepthLabel(queueUiState.localQueueDepth),
            queueUploadStatusChip = queueUploadStatus.first,
            queueUploadStatusMessage = queueUploadStatus.second,
            manualSyncVisible = !syncUiState.isSyncing,
            retryUploadVisible =
                QueueUploadRecoveryVisibility.shouldShowRetryUpload(
                    queueUiState.localQueueDepth,
                    uploadState
                ),
            reloginVisible = requiresRelogin(queueUiState)
        )
    }

    private fun activeEventLabelFor(
        syncUiState: SyncScreenUiState,
        currentEventSyncStatus: AttendeeSyncStatus?
    ): String {
        val eventId = currentEventSyncStatus?.eventId ?: syncUiState.bootstrapEventId
        return if (eventId != null) {
            "Active event: #$eventId"
        } else {
            "Active event: unavailable"
        }
    }

    private fun syncedAttendeeCountLabelFor(currentEventSyncStatus: AttendeeSyncStatus?): String =
        currentEventSyncStatus?.let { "Synced attendees: ${it.attendeeCount}" }
            ?: "Synced attendees: unknown"

    private fun lastSyncLabelFor(currentEventSyncStatus: AttendeeSyncStatus?): String =
        currentEventSyncStatus?.lastSuccessfulSyncAt?.let { "Last sync: $it" }
            ?: "Last sync: unknown"

    private fun primaryRecoveryActionFor(
        uiState: ScanningUiState
    ): Pair<ScanOperatorAction, String>? =
        when (uiState.scannerRecoveryState) {
            is ScannerRecoveryState.RequestPermission ->
                ScanOperatorAction.RequestCameraAccess to "Allow camera access"

            ScannerRecoveryState.OpenSystemSettings ->
                ScanOperatorAction.OpenAppSettings to "Open app settings"

            ScannerRecoveryState.StuckPreview ->
                if (uiState.activeSourceType == ScannerSourceType.CAMERA) {
                    ScanOperatorAction.ReconnectCamera to "Restart camera"
                } else {
                    null
                }

            is ScannerRecoveryState.SourceError ->
                null

            ScannerRecoveryState.Inactive,
            ScannerRecoveryState.Starting,
            ScannerRecoveryState.Ready,
            ScannerRecoveryState.CameraNotRequired ->
                null
        }

    private fun requiresRelogin(queueUiState: QueueUiState): Boolean =
        queueUiState.localQueueDepth > 0 &&
            (queueUiState.uploadSemanticState as? SyncUiState.Failed)?.reason == "Auth expired"

    private fun scannerChipFor(uiState: ScanningUiState): StatusChipUiModel {
        if (uiState.scannerRecoveryState == ScannerRecoveryState.StuckPreview) {
            return StatusChipUiModel(text = "Camera restart required", tone = StatusTone.Warning)
        }

        val blockedReason = (uiState.sessionState as? ScannerSessionState.Blocked)?.reason
        if (
            uiState.activeSourceType == ScannerSourceType.CAMERA &&
            uiState.scannerRecoveryState == ScannerRecoveryState.Starting &&
            blockedReason != ScannerBlockReason.PreviewNotVisible &&
            blockedReason != ScannerBlockReason.PreviewUnavailable
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

                    ScannerBlockReason.PreviewNotVisible ->
                        StatusChipUiModel(text = "Preview loading", tone = StatusTone.Info)

                    ScannerBlockReason.NotAuthenticated ->
                        StatusChipUiModel(text = "Scanner idle", tone = StatusTone.Muted)
                }
        }
    }

    private fun admissionStatusFor(
        syncUiState: SyncScreenUiState,
        currentEventSyncStatus: AttendeeSyncStatus?
    ): Pair<StatusChipUiModel, String> {
        if (currentEventSyncStatus != null) {
            if (currentEventSyncStatus.attendeeCount <= 0) {
                return StatusChipUiModel(
                    text = "No attendees synced",
                    tone = StatusTone.Warning
                ) to "No attendees are currently available in the local cache for this event. Run attendee sync before trusting scanner outcomes."
            }
            return if (isStale(currentEventSyncStatus)) {
                if (currentEventSyncStatus.isSyncStruggling()) {
                    StatusChipUiModel(
                        text = "Sync delayed, scanning continues",
                        tone = StatusTone.Warning
                    ) to
                        "Sync is retrying in the background; you can keep scanning using the saved attendee list."
                } else {
                    StatusChipUiModel(
                        text = "Attendee list may be old",
                        tone = StatusTone.Warning
                    ) to "Using cached attendee data from ${currentEventSyncStatus.lastSuccessfulSyncAt ?: "an earlier sync"}."
                }
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

            uiState.scannerRecoveryState == ScannerRecoveryState.StuckPreview ->
                BannerUiModel(
                    title = "Camera preview stuck",
                    message = uiState.scannerStatus,
                    tone = StatusTone.Warning
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

    private fun queueUploadStatusFor(queueUiState: QueueUiState): Pair<StatusChipUiModel, String> {
        val uploadState = queueUiState.uploadSemanticState
        val queueDepthLabel = queueDepthLabel(queueUiState.localQueueDepth)

        if (uploadState is SyncUiState.Offline && queueUiState.localQueueDepth > 0) {
            return StatusChipUiModel(
                text = "Uploads paused offline",
                tone = StatusTone.Offline
            ) to "$queueDepthLabel will upload automatically when the device reconnects."
        }

        if (uploadState is SyncUiState.Failed && uploadState.reason == "Auth expired") {
            return StatusChipUiModel(
                text = "Re-login required",
                tone = StatusTone.Destructive
            ) to "$queueDepthLabel cannot upload until the operator signs in again."
        }

        return when (uploadState) {
            SyncUiState.Idle ->
                StatusChipUiModel(
                    text = if (queueUiState.localQueueDepth > 0) "Queue waiting" else "No upload backlog",
                    tone = if (queueUiState.localQueueDepth > 0) StatusTone.Warning else StatusTone.Neutral
                ) to if (queueUiState.localQueueDepth > 0) {
                    "$queueDepthLabel is waiting for the next upload attempt."
                } else {
                    "No scans are waiting to upload."
                }

            SyncUiState.Syncing ->
                StatusChipUiModel(
                    text = "Uploading scans",
                    tone = StatusTone.Info
                ) to "$queueDepthLabel is being uploaded to the server."

            is SyncUiState.Synced ->
                StatusChipUiModel(
                    text = "Uploads synced",
                    tone = StatusTone.Success
                ) to if (queueUiState.localQueueDepth > 0) {
                    "$queueDepthLabel remains locally queued after the latest upload result."
                } else {
                    "Latest upload state is synced. No scans are waiting to upload."
                }

            is SyncUiState.Partial ->
                StatusChipUiModel(
                    text = "Backlog remaining",
                    tone = StatusTone.Warning
                ) to "$queueDepthLabel still needs another upload attempt."

            is SyncUiState.Failed ->
                StatusChipUiModel(
                    text = "Upload failed",
                    tone = StatusTone.Destructive
                ) to (
                    uploadState.reason
                        ?.takeIf { it.isNotBlank() }
                        ?.let { "$it. $queueDepthLabel remains local until upload succeeds." }
                        ?: "$queueDepthLabel remains local until upload succeeds."
                    )

            is SyncUiState.Offline ->
                StatusChipUiModel(
                    text = "Offline",
                    tone = StatusTone.Offline
                ) to if (queueUiState.localQueueDepth > 0) {
                    "$queueDepthLabel will upload automatically when the device reconnects."
                } else {
                    "No scans are queued. Uploads will resume when the device reconnects."
                }

            is SyncUiState.RetryScheduled ->
                StatusChipUiModel(
                    text = "Retry scheduled",
                    tone = StatusTone.Warning
                ) to "$queueDepthLabel will retry automatically."
        }
    }

    private companion object {
        const val ADMISSION_SECTION_TITLE = "Admission readiness"
        const val QUEUE_UPLOAD_SECTION_TITLE = "Queue & upload"
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

        return Duration.between(syncedAt, clock.instant()) >
            AdmissionRuntimePolicy.ATTENDEE_CACHE_STALE_THRESHOLD
    }
}
