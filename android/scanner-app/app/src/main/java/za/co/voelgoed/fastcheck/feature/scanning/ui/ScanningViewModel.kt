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
import za.co.voelgoed.fastcheck.feature.scanning.ui.model.ScannerRecoveryState
import za.co.voelgoed.fastcheck.feature.scanning.usecase.CaptureHandoffResult

@HiltViewModel
class ScanningViewModel @Inject constructor() : ViewModel() {
    private val _uiState = MutableStateFlow(ScanningUiState())
    val uiState: StateFlow<ScanningUiState> = _uiState.asStateFlow()
    private var hasAttemptedCameraPermissionRequest: Boolean = false
    private var shouldShowCameraPermissionRationale: Boolean = false

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

    private fun shouldHostPreviewSurface(
        sourceType: ScannerSourceType,
        permission: CameraPermissionState,
        activationDecision: ScannerSourceActivationDecision?
    ): Boolean =
        isCameraSource(sourceType) &&
            permission == CameraPermissionState.GRANTED &&
            when (val sessionState = activationDecision?.sessionState) {
                ScannerSessionState.Armed,
                ScannerSessionState.Active -> true

                is ScannerSessionState.Blocked ->
                    sessionState.reason !in
                        setOf(
                            ScannerBlockReason.NotAuthenticated,
                            ScannerBlockReason.Backgrounded,
                            ScannerBlockReason.PermissionDenied
                        )

                else -> false
            }

    private fun computeScannerStatus(
        sourceType: ScannerSourceType,
        lifecycle: ScannerSourceState,
        permission: CameraPermissionState,
        sessionState: ScannerSessionState,
        shouldHostPreviewSurface: Boolean,
        hasPreviewSurface: Boolean,
        hasBindingAttempted: Boolean,
        isPreviewVisible: Boolean
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
                        "Zebra DataWedge scanner ready. Broadcast captures use local gate rules first, then queue background reconciliation."

                    is ScannerSourceState.Stopping ->
                        "Stopping Zebra DataWedge scanner input source."

                    is ScannerSourceState.Error ->
                        "Zebra DataWedge scanner could not start: ${lifecycle.reason}"

                    else ->
                        if (sessionState == ScannerSessionState.Armed) {
                            "Zebra DataWedge source armed. Broadcast captures will use local gate rules first, then queue background reconciliation."
                        } else {
                            "Zebra DataWedge source selected. Broadcast captures will use local gate rules first, then queue background reconciliation."
                        }
                }

            permission == CameraPermissionState.DENIED ->
                "Camera permission required before scanner preview can start."

            lifecycle is ScannerSourceState.Ready && !isPreviewVisible ->
                "Scanner ready. Preview is still becoming visible in the UI."

            lifecycle is ScannerSourceState.Ready ->
                "Scanner ready. Decoded values use local gate rules first, then queue background reconciliation."

            shouldHostPreviewSurface && !hasPreviewSurface ->
                "Preparing the scan preview"

            hasPreviewSurface && !hasBindingAttempted ->
                "Preparing scanner input source"

            hasBindingAttempted &&
                (lifecycle is ScannerSourceState.Idle || lifecycle is ScannerSourceState.Starting) ->
                "Starting scanner input source"

            lifecycle is ScannerSourceState.Starting ->
                "Preparing scanner input source."

            lifecycle is ScannerSourceState.Stopping ->
                "Stopping scanner input source."

            lifecycle is ScannerSourceState.Error ->
                "Scanner could not start: ${lifecycle.reason}"

            sessionState == ScannerSessionState.Armed ->
                "Scanner armed. Camera scanning is ready to start."

            else ->
                "Scanner scaffold ready. Decoded values will use local gate rules first, then queue background reconciliation."
        }

    private fun scannerRecoveryStateFor(
        sourceType: ScannerSourceType,
        permission: CameraPermissionState,
        lifecycle: ScannerSourceState,
        shouldHostPreviewSurface: Boolean,
        hasPreviewSurface: Boolean,
        hasBindingAttempted: Boolean
    ): ScannerRecoveryState =
        when {
            lifecycle is ScannerSourceState.Error ->
                ScannerRecoveryState.SourceError(lifecycle.reason)

            !isCameraSource(sourceType) ->
                ScannerRecoveryState.CameraNotRequired

            permission == CameraPermissionState.DENIED &&
                hasAttemptedCameraPermissionRequest &&
                !shouldShowCameraPermissionRationale ->
                ScannerRecoveryState.OpenSystemSettings

            permission == CameraPermissionState.DENIED ->
                ScannerRecoveryState.RequestPermission(
                    shouldShowRationale = shouldShowCameraPermissionRationale
                )

            lifecycle is ScannerSourceState.Ready ->
                ScannerRecoveryState.Ready

            shouldHostPreviewSurface && !hasPreviewSurface ->
                ScannerRecoveryState.Starting

            shouldHostPreviewSurface && hasPreviewSurface && !hasBindingAttempted ->
                ScannerRecoveryState.Starting

            shouldHostPreviewSurface &&
                hasBindingAttempted &&
                (lifecycle is ScannerSourceState.Idle || lifecycle is ScannerSourceState.Starting) ->
                ScannerRecoveryState.Starting

            permission == CameraPermissionState.GRANTED ->
                ScannerRecoveryState.Inactive

            else ->
                ScannerRecoveryState.RequestPermission(
                    shouldShowRationale = shouldShowCameraPermissionRationale
                )
        }

    private fun deriveState(current: ScanningUiState): ScanningUiState {
        val sessionState =
            resolveSessionState(
                activationDecision = current.activationDecision,
                lifecycle = current.sourceLifecycle,
                sourceType = current.activeSourceType
            )
        val shouldHostPreviewSurface =
            shouldHostPreviewSurface(
                sourceType = current.activeSourceType,
                permission = current.cameraPermissionState,
                activationDecision = current.activationDecision
            )
        val isSourceReady = current.sourceLifecycle is ScannerSourceState.Ready
        val isPreviewVisible = isCameraSource(current.activeSourceType) && current.isPreviewVisible
        val isPermissionRequestVisible =
            when {
                !isCameraSource(current.activeSourceType) -> false
                current.activationDecision != null ->
                    current.activationDecision.shouldShowCameraPermissionRequest
                else -> true
            }
        val isPermissionRequestEnabled =
            when {
                !isCameraSource(current.activeSourceType) -> false
                current.activationDecision != null ->
                    current.activationDecision.shouldShowCameraPermissionRequest
                else -> current.cameraPermissionState != CameraPermissionState.GRANTED
            }

        return current.copy(
            permissionSummary =
                permissionSummaryFor(current.activeSourceType, current.cameraPermissionState),
            sessionState = sessionState,
            shouldHostPreviewSurface = shouldHostPreviewSurface,
            isPermissionRequestVisible = isPermissionRequestVisible,
            isPermissionRequestEnabled = isPermissionRequestEnabled,
            isSourceReady = isSourceReady,
            sourceErrorMessage =
                when (current.sourceLifecycle) {
                    is ScannerSourceState.Error -> current.sourceLifecycle.reason
                    else -> null
                },
            isPreviewVisible = isPreviewVisible,
            scannerStatus =
                computeScannerStatus(
                    sourceType = current.activeSourceType,
                    lifecycle = current.sourceLifecycle,
                    permission = current.cameraPermissionState,
                    sessionState = sessionState,
                    shouldHostPreviewSurface = shouldHostPreviewSurface,
                    hasPreviewSurface = current.hasPreviewSurface,
                    hasBindingAttempted = current.hasBindingAttempted,
                    isPreviewVisible = isPreviewVisible
                ),
            scannerRecoveryState =
                scannerRecoveryStateFor(
                    sourceType = current.activeSourceType,
                    permission = current.cameraPermissionState,
                    lifecycle = current.sourceLifecycle,
                    shouldHostPreviewSurface = shouldHostPreviewSurface,
                    hasPreviewSurface = current.hasPreviewSurface,
                    hasBindingAttempted = current.hasBindingAttempted
                )
        )
    }

    fun onCaptureHandoffResult(result: CaptureHandoffResult) {
        _uiState.update { current ->
            val feedback =
                when (result) {
                    is CaptureHandoffResult.Accepted ->
                        CaptureFeedbackState.Success(
                            title = "Accepted",
                            message = "Welcome, ${result.displayName}"
                        )

                    is CaptureHandoffResult.Rejected ->
                        CaptureFeedbackState.Warning(
                            title = "Invalid scan",
                            message = result.reason
                        )

                    is CaptureHandoffResult.ReviewRequired ->
                        CaptureFeedbackState.Warning(
                            title = "Manual review",
                            message = result.reason
                        )

                    is CaptureHandoffResult.SuppressedByCooldown ->
                        CaptureFeedbackState.Warning(
                            title = "Repeated scan ignored",
                            message = "Capture ignored during active cooldown."
                        )

                    is CaptureHandoffResult.Failed -> {
                        val message =
                            result.reason.takeIf { it.isNotBlank() } ?: "Could not queue scan"
                        CaptureFeedbackState.Error(
                            title = "Scan failed",
                            message = message
                        )
                    }
                }

            current.copy(
                lastCaptureFeedback = feedback,
                captureSemanticState =
                    when (result) {
                        is CaptureHandoffResult.Accepted -> ScanUiState.AcceptedLocal
                        is CaptureHandoffResult.Rejected -> ScanUiState.Invalid
                        is CaptureHandoffResult.ReviewRequired -> ScanUiState.ManualReview(result.reason)
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
        _uiState.update { current -> deriveState(current.copy(sourceLifecycle = state)) }
    }

    fun refreshPermissionState(
        isGranted: Boolean,
        shouldShowRationale: Boolean = false
    ) {
        shouldShowCameraPermissionRationale = shouldShowRationale
        _uiState.update { current ->
            val newPermission =
                if (isGranted) {
                    CameraPermissionState.GRANTED
                } else {
                    CameraPermissionState.DENIED
                }

            deriveState(
                current.copy(
                    cameraPermissionState = newPermission,
                    hasBindingAttempted = if (isGranted) current.hasBindingAttempted else false
                )
            )
        }
    }

    fun onActivationDecision(decision: ScannerSourceActivationDecision) {
        _uiState.update { current ->
            deriveState(
                current.copy(
                    activationDecision = decision,
                    hasBindingAttempted =
                        if (decision.shouldStartBinding) current.hasBindingAttempted else false
                )
            )
        }
    }

    fun onPermissionRequestStarted() {
        hasAttemptedCameraPermissionRequest = true
        _uiState.update {
            val status =
                if (isCameraSource(it.activeSourceType)) {
                    "Requesting camera permission for scanner input."
                } else {
                    "Camera permission is not required for the active Zebra DataWedge source."
                }
            deriveState(it).copy(scannerStatus = status)
        }
    }

    fun onActiveSourceTypeChanged(sourceType: ScannerSourceType) {
        _uiState.update { current ->
            deriveState(
                current.copy(
                    activeSourceType = sourceType,
                    hasBindingAttempted =
                        if (current.activeSourceType == sourceType) {
                            current.hasBindingAttempted
                        } else {
                            false
                        }
                )
            )
        }
    }

    fun onPreviewSurfaceStateChanged(
        hasPreviewSurface: Boolean,
        isPreviewVisible: Boolean
    ) {
        _uiState.update { current ->
            deriveState(
                current.copy(
                    hasPreviewSurface = hasPreviewSurface,
                    isPreviewVisible = isPreviewVisible
                )
            )
        }
    }

    fun onBindingAttemptChanged(hasBindingAttempted: Boolean) {
        _uiState.update { current ->
            deriveState(current.copy(hasBindingAttempted = hasBindingAttempted))
        }
    }
}
