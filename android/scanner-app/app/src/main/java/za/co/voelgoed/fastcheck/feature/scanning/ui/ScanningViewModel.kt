package za.co.voelgoed.fastcheck.feature.scanning.ui

import androidx.lifecycle.ViewModel
import dagger.hilt.android.lifecycle.HiltViewModel
import javax.inject.Inject
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import za.co.voelgoed.fastcheck.feature.scanning.domain.CameraPermissionState

@HiltViewModel
class ScanningViewModel @Inject constructor() : ViewModel() {
    private val _uiState = MutableStateFlow(ScanningUiState())
    val uiState: StateFlow<ScanningUiState> = _uiState.asStateFlow()

    fun refreshPermissionState(isGranted: Boolean) {
        _uiState.update {
            if (isGranted) {
                it.copy(
                    cameraPermissionState = CameraPermissionState.GRANTED,
                    permissionSummary = "Camera permission granted.",
                    scannerStatus = "Preparing scanner preview and analyzer scaffold.",
                    isPreviewVisible = true,
                    isPermissionRequestEnabled = false
                )
            } else {
                it.copy(
                    cameraPermissionState = CameraPermissionState.DENIED,
                    permissionSummary = "Camera permission required before scanner preview can start.",
                    scannerStatus =
                        "Scanner placeholder is visible. Real capture stays local-first and uses the existing queue path.",
                    isPreviewVisible = false,
                    isPermissionRequestEnabled = true
                )
            }
        }
    }

    fun onPermissionRequestStarted() {
        _uiState.update {
            it.copy(scannerStatus = "Requesting camera permission for scanner preview.")
        }
    }

    fun onScannerBindingStarted() {
        _uiState.update {
            it.copy(scannerStatus = "Binding CameraX preview and ML Kit analyzer.")
        }
    }

    fun onScannerReady() {
        _uiState.update {
            it.copy(
                scannerStatus =
                    "Scanner preview active. Decoded values hand off to the existing local queue only."
            )
        }
    }

    fun onScannerBindingFailed(message: String?) {
        _uiState.update {
            it.copy(
                scannerStatus =
                    if (message.isNullOrBlank()) {
                        "Scanner preview could not start."
                    } else {
                        "Scanner preview could not start: $message"
                    },
                isPreviewVisible = false,
                isPermissionRequestEnabled = true
            )
        }
    }
}
