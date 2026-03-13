package za.co.voelgoed.fastcheck.feature.scanning.ui

import androidx.lifecycle.ViewModel
import dagger.hilt.android.lifecycle.HiltViewModel
import java.time.Clock
import javax.inject.Inject
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import za.co.voelgoed.fastcheck.feature.scanning.camera.CameraPermissionChecker
import za.co.voelgoed.fastcheck.feature.scanning.camera.CameraPermissionState
import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerCandidate
import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerFeedbackConfig
import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerResult
import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerState
import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerStateMachine

@HiltViewModel
class ScanningViewModel @Inject constructor(
    private val scanningUiStateFactory: ScanningUiStateFactory,
    private val cameraPermissionChecker: CameraPermissionChecker,
    private val clock: Clock,
    private val scannerFeedbackConfig: ScannerFeedbackConfig
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

    fun start() {
        transitionTo(ScannerStateMachine.onPermissionUpdated(cameraPermissionChecker.currentState().isGranted()))
    }

    fun refreshPermissionState() {
        transitionTo(ScannerStateMachine.onPermissionUpdated(cameraPermissionChecker.currentState().isGranted()))
    }

    fun onPermissionResult(isGranted: Boolean) {
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
                startedAtEpochMillis = clock.millis(),
                cooldownMillis = scannerFeedbackConfig.resultCooldownMillis
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

    private fun CameraPermissionState.isGranted(): Boolean = this == CameraPermissionState.GRANTED
}
