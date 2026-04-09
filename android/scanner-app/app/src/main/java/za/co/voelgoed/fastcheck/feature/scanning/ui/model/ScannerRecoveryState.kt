package za.co.voelgoed.fastcheck.feature.scanning.ui.model

sealed interface ScannerRecoveryState {
    data object Starting : ScannerRecoveryState

    data object Ready : ScannerRecoveryState

    data class RequestPermission(
        val shouldShowRationale: Boolean
    ) : ScannerRecoveryState

    data object OpenSystemSettings : ScannerRecoveryState

    data object CameraNotRequired : ScannerRecoveryState

    data class SourceError(
        val message: String
    ) : ScannerRecoveryState
}
