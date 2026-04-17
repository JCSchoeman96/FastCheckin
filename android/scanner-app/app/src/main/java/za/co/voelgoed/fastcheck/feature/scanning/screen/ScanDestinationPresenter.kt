package za.co.voelgoed.fastcheck.feature.scanning.screen

import java.time.Clock
import java.time.Duration
import java.time.Instant
import java.time.format.DateTimeFormatter
import java.util.Locale
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
        val scannerDiagnostic = scannerDiagnosticFor(scanningUiState)
        val primaryRecoveryAction = primaryRecoveryActionFor(scanningUiState)

        return ScanDestinationUiState(
            activeEventLabel = activeEventLabelFor(syncUiState, currentEventSyncStatus),
            factLabels =
                listOf(
                    syncedAttendeeCountLabelFor(currentEventSyncStatus),
                    lastSyncLabelFor(currentEventSyncStatus)
                ),
            scannerStatusChip = scannerStatusChip,
            scannerStatusMessage = scanningUiState.scannerStatus,
            scannerDiagnosticLabel = scannerDiagnostic?.first,
            scannerDiagnosticMessage = scannerDiagnostic?.second,
            admissionSectionTitle = ADMISSION_SECTION_TITLE,
            admissionStatusChip = admissionStatus.chip,
            admissionStatusVerdict = admissionStatus.verdict,
            admissionStatusDetail = admissionStatus.detail,
            showCameraPreview = scanningUiState.shouldHostPreviewSurface,
            primaryRecoveryAction = primaryRecoveryAction?.first,
            primaryRecoveryActionLabel = primaryRecoveryAction?.second,
            previewBanner = previewBannerFor(scanningUiState),
            captureBanner = captureBannerFor(scanningUiState.lastCaptureFeedback),
            queueUploadSectionTitle = QUEUE_UPLOAD_SECTION_TITLE,
            queueDepthLabel = queueDepthLabel(queueUiState.localQueueDepth),
            queueUploadStatusChip = queueUploadStatus.chip,
            queueUploadStatusVerdict = queueUploadStatus.verdict,
            queueUploadStatusDetail = queueUploadStatus.detail,
            manualSyncVisible =
                !syncUiState.isSyncing &&
                    shouldShowManualSync(syncUiState, currentEventSyncStatus),
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
        currentEventSyncStatus
            ?.lastSuccessfulSyncAt
            ?.let(::friendlyLastSyncLabel)
            ?: "Last sync unknown"

    private fun friendlyLastSyncLabel(timestamp: String): String {
        val syncedAt =
            runCatching { Instant.parse(timestamp) }
                .getOrNull()
                ?: return "Last sync unknown"
        val now = clock.instant()
        val age = Duration.between(syncedAt, now)

        if (!age.isNegative && age <= Duration.ofSeconds(60)) {
            return "Last sync just now"
        }

        val zone = clock.zone
        val syncedDate = syncedAt.atZone(zone).toLocalDate()
        val today = now.atZone(zone).toLocalDate()
        val formatter =
            if (syncedDate == today) {
                DateTimeFormatter.ofPattern("HH:mm", Locale.US)
            } else {
                DateTimeFormatter.ofPattern("dd MMM HH:mm", Locale.US)
            }

        return "Last sync ${formatter.withZone(zone).format(syncedAt)}"
    }

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

    private fun scannerDiagnosticFor(uiState: ScanningUiState): Pair<String, String>? =
        when (val recoveryState = uiState.scannerRecoveryState) {
            is ScannerRecoveryState.RequestPermission ->
                "Diagnostics" to "Camera permission is required."

            ScannerRecoveryState.OpenSystemSettings ->
                "Diagnostics" to "Camera permission is blocked in system settings."

            is ScannerRecoveryState.SourceError ->
                "Diagnostics" to
                    recoveryState.message
                        .takeIf { it.isNotBlank() }
                        ?.let { "Camera source error: $it" }
                        .orEmpty()
                        .ifBlank { "Camera source error." }

            ScannerRecoveryState.StuckPreview ->
                "Diagnostics" to "Camera preview is not responding."

            ScannerRecoveryState.Starting ->
                if (uiState.sessionState is ScannerSessionState.Blocked) {
                    "Diagnostics" to uiState.scannerStatus
                } else {
                    null
                }

            ScannerRecoveryState.Ready ->
                if (uiState.shouldHostPreviewSurface && !uiState.isPreviewVisible) {
                    "Diagnostics" to "Camera preview is still becoming visible."
                } else {
                    null
                }

            ScannerRecoveryState.Inactive,
            ScannerRecoveryState.CameraNotRequired ->
                null
        }

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
    ): AdmissionStatusUi {
        if (currentEventSyncStatus != null) {
            return if (isStale(currentEventSyncStatus)) {
                if (currentEventSyncStatus.isSyncStruggling()) {
                    AdmissionStatusUi(
                        chip =
                            StatusChipUiModel(
                                text = "Sync delayed",
                                tone = StatusTone.Warning
                            ),
                        verdict = "Admission needs a refresh",
                        detail = "Sync is retrying in the background; saved attendee data is still available."
                    )
                } else {
                    AdmissionStatusUi(
                        chip =
                            StatusChipUiModel(
                                text = "Attendee list may be old",
                                tone = StatusTone.Warning
                            ),
                        verdict = "Admission needs a refresh",
                        detail = "Existing attendee data is available, but a sync should run before heavy scanning."
                    )
                }
            } else {
                AdmissionStatusUi(
                    chip =
                        StatusChipUiModel(
                            text = "Attendee list ready",
                            tone = StatusTone.Success
                        ),
                    verdict = "Ready for admission",
                    detail = "Recent attendee data is available for this event."
                )
            }
        }

        return when (syncUiState.bootstrapStatus) {
            BootstrapSyncStatus.Syncing ->
                AdmissionStatusUi(
                    chip =
                        StatusChipUiModel(
                            text = "Syncing attendee list",
                            tone = StatusTone.Info
                        ),
                    verdict = "Preparing admission data",
                    detail = "Attendees are syncing now."
                )

            BootstrapSyncStatus.Failed ->
                AdmissionStatusUi(
                    chip =
                        StatusChipUiModel(
                            text = "Sync failed",
                            tone = StatusTone.Destructive
                        ),
                    verdict = "Admission refresh failed",
                    detail = "Use manual sync when connectivity is available."
                )

            BootstrapSyncStatus.Succeeded,
            BootstrapSyncStatus.Idle ->
                if (syncUiState.bootstrapEventId != null) {
                    AdmissionStatusUi(
                        chip =
                            StatusChipUiModel(
                                text = "Attendee list not ready",
                                tone = StatusTone.Warning
                            ),
                        verdict = "Admission data missing",
                        detail = "Sync attendees before relying on scan decisions."
                    )
                } else {
                    AdmissionStatusUi(
                        chip =
                            StatusChipUiModel(
                                text = "Attendee list not ready",
                                tone = StatusTone.Warning
                            ),
                        verdict = "Admission unavailable",
                        detail = "Sign in to an event before scanning."
                    )
                }
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

    private fun queueUploadStatusFor(queueUiState: QueueUiState): QueueUploadStatusUi {
        val uploadState = queueUiState.uploadSemanticState

        if (uploadState is SyncUiState.Offline && queueUiState.localQueueDepth > 0) {
            return QueueUploadStatusUi(
                chip =
                    StatusChipUiModel(
                        text = "Uploads paused offline",
                        tone = StatusTone.Offline
                    ),
                verdict = "Queued scans waiting",
                detail = "Uploads will retry automatically when connectivity returns."
            )
        }

        if (uploadState is SyncUiState.Failed && uploadState.reason == "Auth expired") {
            return QueueUploadStatusUi(
                chip =
                    StatusChipUiModel(
                        text = "Re-login required",
                        tone = StatusTone.Destructive
                    ),
                verdict = "Upload paused",
                detail = "Sign in again to resume uploads for this event."
            )
        }

        return when (uploadState) {
            SyncUiState.Idle ->
                QueueUploadStatusUi(
                    chip =
                        StatusChipUiModel(
                            text =
                                if (queueUiState.localQueueDepth > 0) {
                                    "Queue waiting"
                                } else {
                                    "No upload backlog"
                                },
                            tone =
                                if (queueUiState.localQueueDepth > 0) {
                                    StatusTone.Warning
                                } else {
                                    StatusTone.Neutral
                                }
                        ),
                    verdict =
                        if (queueUiState.localQueueDepth > 0) {
                            "Queued scans waiting"
                        } else {
                            "Upload queue clear"
                        },
                    detail =
                        if (queueUiState.localQueueDepth > 0) {
                            "Uploads will retry automatically when connectivity returns."
                        } else {
                            "New scans will still be saved locally before upload."
                        }
                )

            SyncUiState.Syncing ->
                QueueUploadStatusUi(
                    chip =
                        StatusChipUiModel(
                            text = "Uploading scans",
                            tone = StatusTone.Info
                        ),
                    verdict = "Uploading queued scans",
                    detail = "Keep the device online while the queue is being sent."
                )

            is SyncUiState.Synced ->
                if (queueUiState.localQueueDepth > 0) {
                    QueueUploadStatusUi(
                        chip =
                            StatusChipUiModel(
                                text = "Uploads synced",
                                tone = StatusTone.Success
                            ),
                        verdict = "Queued scans waiting",
                        detail = "Some scans remain local after the latest upload result."
                    )
                } else {
                    QueueUploadStatusUi(
                        chip =
                            StatusChipUiModel(
                                text = "Uploads synced",
                                tone = StatusTone.Success
                            ),
                        verdict = "Upload queue clear",
                        detail = "New scans will still be saved locally before upload."
                    )
                }

            is SyncUiState.Partial ->
                QueueUploadStatusUi(
                    chip =
                        StatusChipUiModel(
                            text = "Backlog remaining",
                            tone = StatusTone.Warning
                        ),
                    verdict = "Queued scans waiting",
                    detail = "Uploads will retry automatically when connectivity returns."
                )

            is SyncUiState.Failed ->
                QueueUploadStatusUi(
                    chip =
                        StatusChipUiModel(
                            text = "Upload failed",
                            tone = StatusTone.Destructive
                        ),
                    verdict = "Upload needs attention",
                    detail = "Retry upload when the network is available."
                )

            is SyncUiState.Offline ->
                QueueUploadStatusUi(
                    chip =
                        StatusChipUiModel(
                            text = "Offline",
                            tone = StatusTone.Offline
                        ),
                    verdict =
                        if (queueUiState.localQueueDepth > 0) {
                            "Queued scans waiting"
                        } else {
                            "Upload queue clear"
                        },
                    detail =
                        if (queueUiState.localQueueDepth > 0) {
                            "Uploads will retry automatically when connectivity returns."
                        } else {
                            "New scans will still be saved locally before upload."
                        }
                )

            is SyncUiState.RetryScheduled ->
                QueueUploadStatusUi(
                    chip =
                        StatusChipUiModel(
                            text = "Retry scheduled",
                            tone = StatusTone.Warning
                        ),
                    verdict = "Queued scans waiting",
                    detail = "Uploads will retry automatically when connectivity returns."
                )
        }
    }

    private fun shouldShowManualSync(
        syncUiState: SyncScreenUiState,
        currentEventSyncStatus: AttendeeSyncStatus?
    ): Boolean {
        val hasActiveEvent = currentEventSyncStatus != null || syncUiState.bootstrapEventId != null
        if (!hasActiveEvent) return false

        return currentEventSyncStatus == null ||
            syncUiState.bootstrapStatus == BootstrapSyncStatus.Failed ||
            !syncUiState.errorMessage.isNullOrBlank() ||
            isStale(currentEventSyncStatus) ||
            currentEventSyncStatus.isSyncStruggling()
    }

    private companion object {
        const val ADMISSION_SECTION_TITLE = "Admission readiness"
        const val QUEUE_UPLOAD_SECTION_TITLE = "Queue & upload"
    }

    private data class AdmissionStatusUi(
        val chip: StatusChipUiModel,
        val verdict: String,
        val detail: String
    )

    private data class QueueUploadStatusUi(
        val chip: StatusChipUiModel,
        val verdict: String,
        val detail: String
    )

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
