package za.co.voelgoed.fastcheck.feature.scanning.ui

import javax.inject.Inject
import za.co.voelgoed.fastcheck.feature.scanning.domain.CameraPermissionState
import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerOverlayFactory
import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerState

class ScanningUiStateFactory @Inject constructor() {
    fun create(
        scannerState: ScannerState,
        nowEpochMillis: Long
    ): ScanningUiState {
        val overlayModel = ScannerOverlayFactory.create(scannerState, nowEpochMillis)
        val permissionState = scannerState.permissionState()

        return ScanningUiState(
            scannerState = scannerState,
            overlayModel = overlayModel,
            cameraPermissionState = permissionState,
            permissionSummary = permissionSummary(permissionState),
            scannerStatus = overlayModel.message ?: overlayModel.headline,
            isPreviewVisible = scannerState !is ScannerState.PermissionRequired,
            isPermissionRequestEnabled = scannerState is ScannerState.PermissionRequired
        )
    }

    private fun permissionSummary(permissionState: CameraPermissionState): String =
        when (permissionState) {
            CameraPermissionState.UNKNOWN ->
                "Camera permission status unknown."

            CameraPermissionState.DENIED ->
                "Camera permission required before scanner preview can start."

            CameraPermissionState.GRANTED ->
                "Camera permission granted."
        }
}
