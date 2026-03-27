package za.co.voelgoed.fastcheck.feature.scanning.ui

import androidx.lifecycle.ViewModel
import dagger.hilt.android.lifecycle.HiltViewModel
import javax.inject.Inject
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import za.co.voelgoed.fastcheck.feature.scanning.domain.CameraPermissionState
import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerSourceState
import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerSourceType
import za.co.voelgoed.fastcheck.feature.scanning.ui.model.CaptureFeedbackState
import za.co.voelgoed.fastcheck.feature.scanning.usecase.CaptureHandoffResult

@HiltViewModel
class ScanningViewModel @Inject constructor() : ViewModel() {
    private val _uiState = MutableStateFlow(ScanningUiState())
    val uiState: StateFlow<ScanningUiState> = _uiState.asStateFlow()

    private fun isCameraSource(sourceType: ScannerSourceType): Boolean =
        sourceType == ScannerSourceType.CAMERA

    private fun permissionSummaryFor(
        sourceType: ScannerSourceType,
        permission: CameraPermissionState
    ): String =
        when {
            !isCameraSource(sourceType) ->
                "Camera permission is not required for the active Zebra DataWedge source."
            permission == CameraPermissionState.GRANTED ->
                "Camera permission granted."
            permission == CameraPermissionState.DENIED ->
                "Camera permission required before scanner preview can start."
            else ->
                "Camera permission status unknown."
        }

    private fun shouldShowPreview(
        sourceType: ScannerSourceType,
        permission: CameraPermissionState,
        lifecycle: ScannerSourceState
    ): Boolean =
        isCameraSource(sourceType) &&
            permission == CameraPermissionState.GRANTED &&
            lifecycle is ScannerSourceState.Ready

    private fun computeScannerStatus(
        sourceType: ScannerSourceType,
        lifecycle: ScannerSourceState,
        permission: CameraPermissionState
    ): String =
        if (!isCameraSource(sourceType)) {
            when (lifecycle) {
                is ScannerSourceState.Starting ->
                    "Preparing Zebra DataWedge scanner input source."
                is ScannerSourceState.Ready ->
                    "Zebra DataWedge scanner ready. Broadcast captures hand off to the existing local queue only."
                is ScannerSourceState.Stopping ->
                    "Stopping Zebra DataWedge scanner input source."
                is ScannerSourceState.Error ->
                    "Zebra DataWedge scanner could not start: ${lifecycle.reason}"
                else ->
                    "Zebra DataWedge source selected. Broadcast captures will feed the existing local queue only."
            }
        } else {
            when {
                permission == CameraPermissionState.DENIED ->
                    "Camera permission required before scanner preview can start."
                lifecycle is ScannerSourceState.Starting ->
                    "Preparing scanner input source."
                lifecycle is ScannerSourceState.Ready ->
                    "Scanner ready. Decoded values hand off to the existing local queue only."
                lifecycle is ScannerSourceState.Stopping ->
                    "Stopping scanner input source."
                lifecycle is ScannerSourceState.Error ->
                    "Scanner could not start: ${lifecycle.reason}"
                else ->
                    "Scanner scaffold ready. Decoded values will feed the existing local queue only."
            }
        }

    fun onCaptureHandoffResult(result: CaptureHandoffResult) {
        _uiState.update { current ->
            val feedback =
                when (result) {
                    is CaptureHandoffResult.Accepted ->
                        CaptureFeedbackState.Success("Queued locally (pending upload)")
                    is CaptureHandoffResult.SuppressedByCooldown ->
                        CaptureFeedbackState.Success("Capture ignored during active cooldown.")
                    is CaptureHandoffResult.Failed -> {
                        val message =
                            result.reason.takeIf { it.isNotBlank() } ?: "Could not queue scan"
                        CaptureFeedbackState.Error(message)
                    }
                }

            current.copy(lastCaptureFeedback = feedback)
        }
    }

    fun clearCaptureFeedback() {
        _uiState.update { current ->
            current.copy(lastCaptureFeedback = null)
        }
    }

    fun onSourceStateChanged(state: ScannerSourceState) {
        _uiState.update { current ->
            val isSourceReady = state is ScannerSourceState.Ready
            current.copy(
                sourceLifecycle = state,
                isSourceReady = isSourceReady,
                sourceErrorMessage =
                    when (state) {
                        is ScannerSourceState.Error -> state.reason
                        else -> null
                    },
                isPreviewVisible =
                    shouldShowPreview(current.activeSourceType, current.cameraPermissionState, state),
                scannerStatus =
                    computeScannerStatus(current.activeSourceType, state, current.cameraPermissionState)
            )
        }
    }

    fun refreshPermissionState(isGranted: Boolean) {
        _uiState.update { current ->
            val newPermission =
                if (isGranted) {
                    CameraPermissionState.GRANTED
                } else {
                    CameraPermissionState.DENIED
                }

            current.copy(
                cameraPermissionState = newPermission,
                permissionSummary = permissionSummaryFor(current.activeSourceType, newPermission),
                isPermissionRequestEnabled =
                    isCameraSource(current.activeSourceType) && !isGranted,
                isPermissionRequestVisible = isCameraSource(current.activeSourceType),
                isPreviewVisible =
                    shouldShowPreview(current.activeSourceType, newPermission, current.sourceLifecycle),
                scannerStatus =
                    computeScannerStatus(current.activeSourceType, current.sourceLifecycle, newPermission)
            )
        }
    }

    fun onPermissionRequestStarted() {
        _uiState.update {
            val status =
                if (isCameraSource(it.activeSourceType)) {
                    "Requesting camera permission for scanner input."
                } else {
                    "Camera permission is not required for the active Zebra DataWedge source."
                }
            it.copy(scannerStatus = status)
        }
    }

    fun onActiveSourceTypeChanged(sourceType: ScannerSourceType) {
        _uiState.update { current ->
            current.copy(
                activeSourceType = sourceType,
                permissionSummary = permissionSummaryFor(sourceType, current.cameraPermissionState),
                isPermissionRequestEnabled =
                    isCameraSource(sourceType) &&
                        current.cameraPermissionState != CameraPermissionState.GRANTED,
                isPermissionRequestVisible = isCameraSource(sourceType),
                isPreviewVisible =
                    shouldShowPreview(sourceType, current.cameraPermissionState, current.sourceLifecycle),
                scannerStatus =
                    computeScannerStatus(sourceType, current.sourceLifecycle, current.cameraPermissionState)
            )
        }
    }

    // Scanner binding and lifecycle are now owned by ScannerSourceBinding and the
    // Android shell. ViewModel observes source state via onSourceStateChanged.
}
