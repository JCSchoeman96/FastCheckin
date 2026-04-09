package za.co.voelgoed.fastcheck.feature.support

import za.co.voelgoed.fastcheck.core.designsystem.semantic.StatusTone
import za.co.voelgoed.fastcheck.core.designsystem.semantic.SyncUiState
import za.co.voelgoed.fastcheck.domain.model.EventAttendeeCacheMetrics
import za.co.voelgoed.fastcheck.feature.queue.QueueUploadRecoveryVisibility
import za.co.voelgoed.fastcheck.feature.queue.QueueUiState
import za.co.voelgoed.fastcheck.feature.scanning.ui.ScanningUiState
import za.co.voelgoed.fastcheck.feature.scanning.ui.model.ScannerRecoveryState
import za.co.voelgoed.fastcheck.feature.support.model.SupportOperationalAction
import za.co.voelgoed.fastcheck.feature.support.model.SupportOperationalActionUiModel
import za.co.voelgoed.fastcheck.feature.sync.SyncScreenUiState

class SupportOverviewPresenter {
    fun present(
        scanningUiState: ScanningUiState,
        attendeeMetrics: EventAttendeeCacheMetrics?,
        queueUiState: QueueUiState,
        syncUiState: SyncScreenUiState
    ): SupportOverviewUiState {
        val recovery =
            when (val state = scanningUiState.scannerRecoveryState) {
                ScannerRecoveryState.CameraNotRequired ->
                    RecoveryCopy(
                        title = "Camera access not required",
                        message = "The current scanner source does not use the smartphone camera. Return to Scan when you are ready to continue.",
                        tone = StatusTone.Neutral,
                        action = SupportRecoveryAction.ReturnToScan
                    )

                ScannerRecoveryState.Starting ->
                    RecoveryCopy(
                        title = "Scanner startup in progress",
                        message = "Camera startup is still in progress. Return to Scan to continue while the scanner finishes preparing.",
                        tone = StatusTone.Info,
                        action = SupportRecoveryAction.ReturnToScan
                    )

                ScannerRecoveryState.Ready ->
                    RecoveryCopy(
                        title = "Scanner access ready",
                        message = "Camera access is available for smartphone scanning. Return to Scan to continue operating.",
                        tone = StatusTone.Success,
                        action = SupportRecoveryAction.ReturnToScan
                    )

                is ScannerRecoveryState.RequestPermission ->
                    RecoveryCopy(
                        title = "Camera access needed",
                        message =
                            if (state.shouldShowRationale) {
                                "Camera access was denied earlier. Request it again when you are ready to resume smartphone scanning."
                            } else {
                                "Allow camera access to use smartphone scanning on this device."
                            },
                        tone = StatusTone.Warning,
                        action = SupportRecoveryAction.RequestCameraAccess
                    )

                ScannerRecoveryState.OpenSystemSettings ->
                    RecoveryCopy(
                        title = "Open app settings",
                        message = "Camera access is blocked for future prompts. Open app settings to re-enable smartphone scanning.",
                        tone = StatusTone.Warning,
                        action = SupportRecoveryAction.OpenAppSettings
                    )

                is ScannerRecoveryState.SourceError ->
                    RecoveryCopy(
                        title = "Scanner unavailable",
                        message = "The scanner could not start: ${state.message}. Return to Scan after the current issue is cleared.",
                        tone = StatusTone.Destructive,
                        action = SupportRecoveryAction.ReturnToScan
                    )
            }

        val reconciliation =
            if (attendeeMetrics != null && attendeeMetrics.unresolvedConflictCount > 0) {
                Triple(
                    "Reconciliation conflicts active",
                    "${attendeeMetrics.unresolvedConflictCount} attendee conflict(s) still block green admission on this device. " +
                        "Use Event and Search to review affected records before admitting them again.",
                    StatusTone.Warning
                )
            } else if (attendeeMetrics != null && attendeeMetrics.activeOverlayCount > 0) {
                Triple(
                    "Local admissions still awaiting server catch-up",
                    "${attendeeMetrics.activeOverlayCount} local admission overlay(s) remain active until a later attendee sync reflects them.",
                    StatusTone.Info
                )
            } else {
                null
            }

        val uploadQuarantineNotice =
            if (queueUiState.quarantineCount > 0) {
                "${queueUiState.quarantineCount} scan row(s) are in upload quarantine " +
                    "(removed from the retry backlog after unrecoverable upload errors). " +
                    "Open Diagnostics for read-only details."
            } else {
                null
            }

        return SupportOverviewUiState(
            recoveryTitle = recovery.title,
            recoveryMessage = recovery.message,
            recoveryTone = recovery.tone,
            recoveryAction = recovery.action,
            operationalActions = operationalActionsFor(queueUiState, syncUiState),
            reconciliationTitle = reconciliation?.first,
            reconciliationMessage = reconciliation?.second,
            reconciliationTone = reconciliation?.third,
            diagnosticsMessage =
                "Diagnostics is read-only: session, sync, queue depth, flush, and upload quarantine facts. " +
                    "It does not run uploads or change server state.",
            sessionMessage =
                "End this event session on this device when the operator is finished. Logging out is not required to clear upload quarantine.",
            uploadQuarantineNotice = uploadQuarantineNotice
        )
    }

    private fun operationalActionsFor(
        queueUiState: QueueUiState,
        syncUiState: SyncScreenUiState
    ): List<SupportOperationalActionUiModel> {
        val actions = mutableListOf<SupportOperationalActionUiModel>()
        if (!syncUiState.isSyncing) {
            actions.add(
                SupportOperationalActionUiModel(
                    label = "Sync attendee list",
                    action = SupportOperationalAction.ManualSync
                )
            )
        }
        if (
            QueueUploadRecoveryVisibility.shouldShowRetryUpload(
                queueUiState.localQueueDepth,
                queueUiState.uploadSemanticState
            )
        ) {
            actions.add(
                SupportOperationalActionUiModel(
                    label = "Retry upload",
                    action = SupportOperationalAction.RetryUpload
                )
            )
        }
        if (requiresRelogin(queueUiState)) {
            actions.add(
                SupportOperationalActionUiModel(
                    label = "Re-login",
                    action = SupportOperationalAction.Relogin
                )
            )
        }
        return actions
    }

    private fun requiresRelogin(queueUiState: QueueUiState): Boolean =
        queueUiState.localQueueDepth > 0 &&
            (queueUiState.uploadSemanticState as? SyncUiState.Failed)?.reason == "Auth expired"

    private data class RecoveryCopy(
        val title: String,
        val message: String,
        val tone: StatusTone,
        val action: SupportRecoveryAction?
    )
}
