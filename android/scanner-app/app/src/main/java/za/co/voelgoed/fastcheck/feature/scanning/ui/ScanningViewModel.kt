package za.co.voelgoed.fastcheck.feature.scanning.ui

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import java.time.Clock
import javax.inject.Inject
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import za.co.voelgoed.fastcheck.feature.scanning.camera.CameraPermissionChecker
import za.co.voelgoed.fastcheck.feature.scanning.camera.CameraPermissionState
import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerCandidate
import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerFeedbackConfig
import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerResult
import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerState
import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerStateMachine
import za.co.voelgoed.fastcheck.feature.scanning.usecase.ScannerLoopController
import za.co.voelgoed.fastcheck.feature.scanning.usecase.ScannerLoopEvent

@HiltViewModel
class ScanningViewModel @Inject constructor(
    private val scanningUiStateFactory: ScanningUiStateFactory,
    private val cameraPermissionChecker: CameraPermissionChecker,
    private val clock: Clock,
    private val scannerFeedbackConfig: ScannerFeedbackConfig,
    private val scannerLoopController: ScannerLoopController
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
    private var cooldownJob: Job? = null

    init {
        viewModelScope.launch {
            scannerLoopController.events.collect { event ->
                when (event) {
                    is ScannerLoopEvent.CandidateAccepted -> onCandidateDetected(event.candidate)
                    is ScannerLoopEvent.ProcessingStarted -> onProcessingStarted(event.candidate)
                    is ScannerLoopEvent.ImmediateResult -> {
                        onImmediateResult(event.result)
                        onCooldownStarted(event.result)
                    }
                }
            }
        }
    }

    fun start() {
        scannerLoopController.reset()
        cancelCooldown()
        transitionTo(ScannerStateMachine.onPermissionUpdated(cameraPermissionChecker.currentState().isGranted()))
    }

    fun refreshPermissionState() {
        transitionTo(ScannerStateMachine.onPermissionUpdated(cameraPermissionChecker.currentState().isGranted()))
    }

    fun onPermissionResult(isGranted: Boolean) {
        if (!isGranted) {
            scannerLoopController.reset()
            cancelCooldown()
        }
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
        scannerLoopController.reset()
        cancelCooldown()
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
        cancelCooldown()
        transitionTo(
            ScannerStateMachine.onCooldownStarted(
                result = result,
                startedAtEpochMillis = clock.millis(),
                cooldownMillis = scannerFeedbackConfig.resultCooldownMillis
            )
        )
        cooldownJob =
            viewModelScope.launch {
                delay(scannerFeedbackConfig.resultCooldownMillis)
                onCooldownComplete()
            }
    }

    fun onCooldownComplete() {
        scannerLoopController.onCooldownComplete()
        cooldownJob = null
        transitionTo(ScannerStateMachine.onCooldownComplete())
    }

    private fun transitionTo(scannerState: ScannerState) {
        _uiState.value =
            scanningUiStateFactory.create(
                scannerState = scannerState,
                nowEpochMillis = clock.millis()
            )
    }

    private fun cancelCooldown() {
        cooldownJob?.cancel()
        cooldownJob = null
    }

    private fun CameraPermissionState.isGranted(): Boolean = this == CameraPermissionState.GRANTED
}
