package za.co.voelgoed.fastcheck.feature.scanning.ui

import androidx.lifecycle.ViewModel
import dagger.hilt.android.lifecycle.HiltViewModel
import javax.inject.Inject
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import za.co.voelgoed.fastcheck.app.scanning.ScannerBlockReason
import za.co.voelgoed.fastcheck.app.scanning.ScannerSessionState
import za.co.voelgoed.fastcheck.app.scanning.ScannerSourceActivationDecision
import za.co.voelgoed.fastcheck.core.designsystem.semantic.ScanUiState
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

    private fun resolveSessionState(
        activationDecision: ScannerSourceActivationDecision?,
        lifecycle: ScannerSourceState,
        sourceType: ScannerSourceType
    ): ScannerSessionState {
        val requestedState = activationDecision?.sessionState ?: ScannerSessionState.Idle

        if (requestedState !is ScannerSessionState.Armed) {
            return requestedState
        }

        return when {
            lifecycle is ScannerSourceState.Error ->
                ScannerSessionState.Blocked(ScannerBlockReason.SourceError)

            lifecycle is ScannerSourceState.Ready && !isCameraSource(sourceType) ->
                ScannerSessionState.Active

            lifecycle is ScannerSourceState.Ready &&
                activationDecision?.shouldStartBinding == true ->
                ScannerSessionState.Active

            else ->
                ScannerSessionState.Armed
        }
    }

    private fun shouldShowPreview(
        sourceType: ScannerSourceType,
        permission: CameraPermissionState,
        sessionState: ScannerSessionState
    ): Boolean =
        isCameraSource(sourceType) &&
            permission == CameraPermissionState.GRANTED &&
            sessionState in setOf(ScannerSessionState.Armed, ScannerSessionState.Active)

    private fun computeScannerStatus(
        sourceType: ScannerSourceType,
        lifecycle: ScannerSourceState,
        permission: CameraPermissionState,
        sessionState: ScannerSessionState
    ): String =
        when {
            sessionState is ScannerSessionState.Blocked &&
                sessionState.reason == ScannerBlockReason.PermissionDenied ->
                "Camera permission required before scanner preview can start."

            sessionState is ScannerSessionState.Blocked &&
                sessionState.reason == ScannerBlockReason.Backgrounded ->
                "Scanner paused while the app is in the background."

            sessionState is ScannerSessionState.Blocked &&
                sessionState.reason == ScannerBlockReason.PreviewUnavailable ->
                "Preparing the scan preview before camera scanning can start."

            !isCameraSource(sourceType) ->
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
                        if (sessionState == ScannerSessionState.Armed) {
                            "Zebra DataWedge source armed. Broadcast captures will feed the existing local queue only."
                        } else {
                            "Zebra DataWedge source selected. Broadcast captures will feed the existing local queue only."
                        }
                }

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

            sessionState == ScannerSessionState.Armed ->
                "Scanner armed. Camera scanning is ready to start."

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
                        CaptureFeedbackState.Warning("Capture ignored during active cooldown.")

                    is CaptureHandoffResult.Failed -> {
                        val message =
                            result.reason.takeIf { it.isNotBlank() } ?: "Could not queue scan"
                        CaptureFeedbackState.Error(message)
                    }
                }

            current.copy(
                lastCaptureFeedback = feedback,
                captureSemanticState =
                    when (result) {
                        is CaptureHandoffResult.Accepted -> ScanUiState.QueuedLocally
                        is CaptureHandoffResult.SuppressedByCooldown -> ScanUiState.Suppressed
                        is CaptureHandoffResult.Failed -> ScanUiState.Failed(result.reason)
                    }
            )
        }
    }

    fun clearCaptureFeedback() {
        _uiState.update { current ->
            current.copy(lastCaptureFeedback = null, captureSemanticState = null)
        }
    }

    fun onSourceStateChanged(state: ScannerSourceState) {
        _uiState.update { current ->
            val sessionState =
                resolveSessionState(
                    activationDecision = current.activationDecision,
                    lifecycle = state,
                    sourceType = current.activeSourceType
                )

            current.copy(
                sourceLifecycle = state,
                sessionState = sessionState,
                isSourceReady = state is ScannerSourceState.Ready,
                sourceErrorMessage =
                    when (state) {
                        is ScannerSourceState.Error -> state.reason
                        else -> null
                    },
                isPreviewVisible =
                    shouldShowPreview(
                        current.activeSourceType,
                        current.cameraPermissionState,
                        sessionState
                    ),
                scannerStatus =
                    computeScannerStatus(
                        current.activeSourceType,
                        state,
                        current.cameraPermissionState,
                        sessionState
                    )
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
                    current.activationDecision?.shouldShowCameraPermissionRequest
                        ?: (isCameraSource(current.activeSourceType) && !isGranted),
                isPermissionRequestVisible =
                    current.activationDecision?.shouldShowCameraPermissionRequest
                        ?: isCameraSource(current.activeSourceType),
                isPreviewVisible =
                    shouldShowPreview(
                        current.activeSourceType,
                        newPermission,
                        current.sessionState
                    ),
                scannerStatus =
                    computeScannerStatus(
                        current.activeSourceType,
                        current.sourceLifecycle,
                        newPermission,
                        current.sessionState
                    )
            )
        }
    }

    fun onActivationDecision(decision: ScannerSourceActivationDecision) {
        _uiState.update { current ->
            val sessionState =
                resolveSessionState(
                    activationDecision = decision,
                    lifecycle = current.sourceLifecycle,
                    sourceType = current.activeSourceType
                )

            current.copy(
                activationDecision = decision,
                sessionState = sessionState,
                isPermissionRequestEnabled = decision.shouldShowCameraPermissionRequest,
                isPermissionRequestVisible = decision.shouldShowCameraPermissionRequest,
                isPreviewVisible =
                    shouldShowPreview(
                        current.activeSourceType,
                        current.cameraPermissionState,
                        sessionState
                    ),
                scannerStatus =
                    computeScannerStatus(
                        current.activeSourceType,
                        current.sourceLifecycle,
                        current.cameraPermissionState,
                        sessionState
                    )
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
                    shouldShowPreview(sourceType, current.cameraPermissionState, current.sessionState),
                scannerStatus =
                    computeScannerStatus(
                        sourceType,
                        current.sourceLifecycle,
                        current.cameraPermissionState,
                        current.sessionState
                    )
            )
        }
    }
}
