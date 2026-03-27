package za.co.voelgoed.fastcheck.feature.scanning.ui

import za.co.voelgoed.fastcheck.feature.scanning.domain.CameraPermissionState
import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerSourceState
import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerSourceType
import za.co.voelgoed.fastcheck.feature.scanning.ui.model.CaptureFeedbackState

data class ScanningUiState(
    val activeSourceType: ScannerSourceType = ScannerSourceType.CAMERA,
    val cameraPermissionState: CameraPermissionState = CameraPermissionState.UNKNOWN,
    val permissionSummary: String = "Camera permission status unknown.",
    val scannerStatus: String =
        "Scanner scaffold ready. Decoded values will feed the existing local queue only.",
    val isPreviewVisible: Boolean = false,
    val isPermissionRequestEnabled: Boolean = true,
    val isPermissionRequestVisible: Boolean = true,
    val sourceLifecycle: ScannerSourceState = ScannerSourceState.Idle,
    val isSourceReady: Boolean = false,
    val sourceErrorMessage: String? = null,
    val lastCaptureFeedback: CaptureFeedbackState? = null
)
