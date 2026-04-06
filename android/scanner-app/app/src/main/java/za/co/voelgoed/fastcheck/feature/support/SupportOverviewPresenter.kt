package za.co.voelgoed.fastcheck.feature.support

import za.co.voelgoed.fastcheck.core.designsystem.semantic.StatusTone
import za.co.voelgoed.fastcheck.domain.model.EventAttendeeCacheMetrics
import za.co.voelgoed.fastcheck.feature.scanning.ui.ScanningUiState
import za.co.voelgoed.fastcheck.feature.scanning.ui.model.ScannerRecoveryState

class SupportOverviewPresenter {
    fun present(
        scanningUiState: ScanningUiState,
        attendeeMetrics: EventAttendeeCacheMetrics?
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

        return SupportOverviewUiState(
            recoveryTitle = recovery.title,
            recoveryMessage = recovery.message,
            recoveryTone = recovery.tone,
            recoveryAction = recovery.action,
            reconciliationTitle = reconciliation?.first,
            reconciliationMessage = reconciliation?.second,
            reconciliationTone = reconciliation?.third,
            diagnosticsMessage = "Diagnostics stays available here for support work. It does not appear in the main operator navigation.",
            sessionMessage = "Log out of the current event session when the operator is finished on this device."
        )
    }

    private data class RecoveryCopy(
        val title: String,
        val message: String,
        val tone: StatusTone,
        val action: SupportRecoveryAction?
    )
}
