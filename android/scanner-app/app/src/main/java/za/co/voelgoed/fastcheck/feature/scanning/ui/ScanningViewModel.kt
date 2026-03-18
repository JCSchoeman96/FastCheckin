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
import za.co.voelgoed.fastcheck.feature.scanning.ui.model.CaptureFeedbackState
import za.co.voelgoed.fastcheck.feature.scanning.usecase.CaptureHandoffResult

@HiltViewModel
class ScanningViewModel @Inject constructor() : ViewModel() {
    private val _uiState = MutableStateFlow(ScanningUiState())
    val uiState: StateFlow<ScanningUiState> = _uiState.asStateFlow()

    private fun shouldShowPreview(
        permission: CameraPermissionState,
        lifecycle: ScannerSourceState
    ): Boolean =
        permission == CameraPermissionState.GRANTED &&
            lifecycle is ScannerSourceState.Ready

    private fun computeScannerStatus(
        lifecycle: ScannerSourceState,
        permission: CameraPermissionState
    ): String =
        when {
            permission == CameraPermissionState.DENIED ->
                "Camera permission required before scanner preview can start."
            lifecycle is ScannerSourceState.Starting ->
                "Preparing scanner input source."
            lifecycle is ScannerSourceState.Ready ->
                "Scanner ready. Decoded values hand off to the existing local queue only."
            lifecycle is ScannerSourceState.Error ->
                "Scanner could not start: ${lifecycle.reason}"
            else ->
                "Scanner scaffold ready. Decoded values will feed the existing local queue only."
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
                isPreviewVisible = shouldShowPreview(current.cameraPermissionState, state),
                scannerStatus = computeScannerStatus(state, current.cameraPermissionState)
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
                permissionSummary =
                    if (isGranted) {
                        "Camera permission granted."
                    } else {
                        "Camera permission required before scanner preview can start."
                    },
                isPermissionRequestEnabled = !isGranted,
                isPreviewVisible = shouldShowPreview(newPermission, current.sourceLifecycle),
                scannerStatus = computeScannerStatus(current.sourceLifecycle, newPermission)
            )
        }
    }

    fun onPermissionRequestStarted() {
        _uiState.update {
            it.copy(scannerStatus = "Requesting camera permission for scanner input.")
        }
    }

    // Scanner binding and lifecycle are now owned by ScannerSourceBinding and the
    // Android shell. ViewModel observes source state via onSourceStateChanged.
}
