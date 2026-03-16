package za.co.voelgoed.fastcheck.feature.scanning.ui

import za.co.voelgoed.fastcheck.feature.scanning.camera.CameraPermissionState
import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerOverlayEmphasis
import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerOverlayModel
import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerState

data class ScanningUiState(
    val scannerState: ScannerState =
        ScannerState.PermissionRequired(
            permissionState = CameraPermissionState.UNKNOWN,
            prompt = "Camera permission status unknown."
        ),
    val overlayModel: ScannerOverlayModel =
        ScannerOverlayModel(
            visible = true,
            headline = "Camera permission required",
            message = "Camera permission status unknown.",
            candidateText = null,
            emphasis = ScannerOverlayEmphasis.WARNING,
            cooldownRemainingMillis = null
        ),
    val cameraPermissionState: CameraPermissionState = CameraPermissionState.UNKNOWN,
    val permissionUiState: ScannerPermissionUiState =
        ScannerPermissionUiState(
            visible = true,
            headline = "Camera permission",
            message = "Camera permission status unknown.",
            requestButtonLabel = "Request Camera Permission",
            isRequestEnabled = true
        ),
    val permissionSummary: String = "Camera permission status unknown.",
    val scannerStatus: String =
        "Scanner scaffold ready. Decoded values will feed the existing local queue only.",
    val isPreviewVisible: Boolean = false,
    val isPermissionRequestEnabled: Boolean = true
)
