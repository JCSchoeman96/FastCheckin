package za.co.voelgoed.fastcheck.feature.scanning.ui

import androidx.lifecycle.ViewModel
import dagger.hilt.android.lifecycle.HiltViewModel
import java.time.Clock
import javax.inject.Inject
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import za.co.voelgoed.fastcheck.feature.scanning.domain.CameraPermissionState
import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerCandidate
import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerResult
import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerState
import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerStateMachine

@HiltViewModel
class ScanningViewModel @Inject constructor(
    private val scanningUiStateFactory: ScanningUiStateFactory,
    private val clock: Clock
) : ViewModel() {
    private val _uiState =
        MutableStateFlow(
            scanningUiStateFactory.create(
                scannerState =
                    ScannerStateMachine.permissionRequired(CameraPermissionState.UNKNOWN),
                nowEpochMillis = clock.millis()
            )
    )
    val uiState: StateFlow<ScanningUiState> = _uiState.asStateFlow()

    fun refreshPermissionState(isGranted: Boolean) {
        transitionTo(ScannerStateMachine.onPermissionUpdated(isGranted))
    }

    fun onPermissionRequestStarted() {
        transitionTo(
            ScannerStateMachine.onPermissionRequestStarted(_uiState.value.cameraPermissionState)
        )
    }

    fun onScannerBindingStarted() {
        transitionTo(ScannerStateMachine.onCameraBindingStarted())
    }

    fun onScannerReady() {
        transitionTo(ScannerStateMachine.onCameraReady())
    }

    fun onScannerBindingFailed(message: String?) {
        transitionTo(
            ScannerStateMachine.onCameraFailure(
                permissionState = _uiState.value.cameraPermissionState,
                message = message,
                retryable = true
            )
        )
    }

    fun onCandidateDetected(candidate: ScannerCandidate) {
        transitionTo(ScannerStateMachine.onCandidateDetected(candidate))
    }

    fun onProcessingStarted(candidate: ScannerCandidate) {
        transitionTo(ScannerStateMachine.onProcessingStarted(candidate))
    }

    fun onImmediateResult(result: ScannerResult) {
        transitionTo(ScannerStateMachine.onResultVisible(result))
    }

    fun onCooldownStarted(result: ScannerResult) {
        transitionTo(
            ScannerStateMachine.onCooldownStarted(
                result = result,
                startedAtEpochMillis = clock.millis()
            )
        )
    }

    fun onCooldownComplete() {
        transitionTo(ScannerStateMachine.onCooldownComplete())
    }

    private fun transitionTo(scannerState: ScannerState) {
        _uiState.value =
            scanningUiStateFactory.create(
                scannerState = scannerState,
                nowEpochMillis = clock.millis()
            )
    }
}
