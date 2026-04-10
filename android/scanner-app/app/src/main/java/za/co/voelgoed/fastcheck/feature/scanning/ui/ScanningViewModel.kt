package za.co.voelgoed.fastcheck.feature.scanning.ui

import androidx.lifecycle.ViewModel
import dagger.hilt.android.lifecycle.HiltViewModel
import javax.inject.Inject
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import za.co.voelgoed.fastcheck.app.scanning.ScannerBlockReason
import za.co.voelgoed.fastcheck.app.scanning.ScannerSessionState
import za.co.voelgoed.fastcheck.app.scanning.ScannerSourceActivationDecision
import za.co.voelgoed.fastcheck.core.common.AppDispatchers
import za.co.voelgoed.fastcheck.core.designsystem.semantic.ScanUiState
import za.co.voelgoed.fastcheck.feature.scanning.analysis.DecodeDiagnostic
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
    private var stuckPreviewTimeoutJob: Job? = null
    private var captureFeedbackClearJob: Job? = null
    private var timeoutDispatcher: CoroutineDispatcher = Dispatchers.Default
    private var timeoutScope: CoroutineScope = CoroutineScope(SupervisorJob() + timeoutDispatcher)
    private var stuckPreviewTimeoutMs: Long = STUCK_PREVIEW_TIMEOUT_MS
    private var lastDecodeDiagnosticAtMillis: Long = 0L

    internal constructor(
        appDispatchers: AppDispatchers,
        stuckPreviewTimeoutMs: Long = STUCK_PREVIEW_TIMEOUT_MS
    ) : this() {
        timeoutDispatcher = appDispatchers.main
        timeoutScope = CoroutineScope(SupervisorJob() + timeoutDispatcher)
        this.stuckPreviewTimeoutMs = stuckPreviewTimeoutMs
    }

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
        recoveryState: ScannerRecoveryState,
        shouldHostPreviewSurface: Boolean,
        hasPreviewSurface: Boolean,
        hasBindingAttempted: Boolean,
        isPreviewVisible: Boolean
    ): String =
        when {
            recoveryState == ScannerRecoveryState.StuckPreview ->
                STUCK_PREVIEW_STATUS

            sessionState is ScannerSessionState.Blocked &&
                sessionState.reason == ScannerBlockReason.PermissionDenied ->
                "Camera permission required before scanner preview can start."

            sessionState is ScannerSessionState.Blocked &&
                sessionState.reason == ScannerBlockReason.Backgrounded ->
                "Scanner paused while the app is in the background."

            sessionState is ScannerSessionState.Blocked &&
                sessionState.reason == ScannerBlockReason.PreviewUnavailable ->
                "Preparing the scan preview before camera scanning can start."

            sessionState is ScannerSessionState.Blocked &&
                sessionState.reason == ScannerBlockReason.PreviewNotVisible ->
                "Camera preview is becoming visible. Scanner will start automatically."

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

    private fun isStuckPreviewCandidate(
        sourceType: ScannerSourceType,
        permission: CameraPermissionState,
        activationDecision: ScannerSourceActivationDecision?,
        shouldHostPreviewSurface: Boolean,
        isPreviewVisible: Boolean,
        hasBindingAttempted: Boolean,
        lifecycle: ScannerSourceState
    ): Boolean =
        isCameraSource(sourceType) &&
            permission == CameraPermissionState.GRANTED &&
            activationDecision?.shouldStartBinding == true &&
            shouldHostPreviewSurface &&
            hasBindingAttempted &&
            !isPreviewVisible &&
            lifecycle !is ScannerSourceState.Stopping &&
            lifecycle !is ScannerSourceState.Error

    private fun isStuckPreviewCandidate(state: ScanningUiState): Boolean =
        isStuckPreviewCandidate(
            sourceType = state.activeSourceType,
            permission = state.cameraPermissionState,
            activationDecision = state.activationDecision,
            shouldHostPreviewSurface = state.shouldHostPreviewSurface,
            isPreviewVisible = state.isPreviewVisible,
            hasBindingAttempted = state.hasBindingAttempted,
            lifecycle = state.sourceLifecycle
        )

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
        val computedRecoveryState =
            scannerRecoveryStateFor(
                sourceType = current.activeSourceType,
                permission = current.cameraPermissionState,
                lifecycle = current.sourceLifecycle,
                shouldHostPreviewSurface = shouldHostPreviewSurface,
                hasPreviewSurface = current.hasPreviewSurface,
                hasBindingAttempted = current.hasBindingAttempted
            )
        val shouldKeepStuckPreview =
            current.scannerRecoveryState == ScannerRecoveryState.StuckPreview &&
                isStuckPreviewCandidate(
                    sourceType = current.activeSourceType,
                    permission = current.cameraPermissionState,
                    activationDecision = current.activationDecision,
                    shouldHostPreviewSurface = shouldHostPreviewSurface,
                    isPreviewVisible = isPreviewVisible,
                    hasBindingAttempted = current.hasBindingAttempted,
                    lifecycle = current.sourceLifecycle
                )
        val recoveryState =
            if (shouldKeepStuckPreview) {
                ScannerRecoveryState.StuckPreview
            } else {
                computedRecoveryState
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
                    recoveryState = recoveryState,
                    shouldHostPreviewSurface = shouldHostPreviewSurface,
                    hasPreviewSurface = current.hasPreviewSurface,
                    hasBindingAttempted = current.hasBindingAttempted,
                    isPreviewVisible = isPreviewVisible
                ),
            scannerRecoveryState = recoveryState
        )
    }

    private fun updateUiState(transform: (ScanningUiState) -> ScanningUiState) {
        _uiState.update { current ->
            deriveState(transform(current))
        }
        syncStuckPreviewTimeout()
    }

    private fun syncStuckPreviewTimeout() {
        val state = _uiState.value
        if (!isStuckPreviewCandidate(state) || state.scannerRecoveryState == ScannerRecoveryState.StuckPreview) {
            stuckPreviewTimeoutJob?.cancel()
            stuckPreviewTimeoutJob = null
            return
        }
        if (stuckPreviewTimeoutJob != null) return

        stuckPreviewTimeoutJob =
            timeoutScope.launch {
                delay(stuckPreviewTimeoutMs)
                val latest = _uiState.value
                if (!isStuckPreviewCandidate(latest)) {
                    return@launch
                }
                _uiState.update { current ->
                    deriveState(
                        current.copy(
                            scannerRecoveryState = ScannerRecoveryState.StuckPreview
                        )
                    )
                }
            }.also { job ->
                job.invokeOnCompletion {
                    if (stuckPreviewTimeoutJob === job) {
                        stuckPreviewTimeoutJob = null
                    }
                }
            }
    }

    fun onCaptureHandoffResult(result: CaptureHandoffResult) {
        if (result is CaptureHandoffResult.SuppressedByCooldown) {
            return
        }
        updateUiState { current ->
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
                        current.lastCaptureFeedback

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
        scheduleCaptureFeedbackClear()
    }

    fun clearCaptureFeedback() {
        captureFeedbackClearJob?.cancel()
        captureFeedbackClearJob = null
        updateUiState { current ->
            current.copy(lastCaptureFeedback = null, captureSemanticState = null)
        }
    }

    private fun scheduleCaptureFeedbackClear() {
        captureFeedbackClearJob?.cancel()
        captureFeedbackClearJob =
            timeoutScope.launch {
                delay(CAPTURE_FEEDBACK_AUTO_CLEAR_MS)
                updateUiState { current ->
                    current.copy(lastCaptureFeedback = null, captureSemanticState = null)
                }
                captureFeedbackClearJob = null
            }
    }

    fun onSourceStateChanged(state: ScannerSourceState) {
        updateUiState { current -> current.copy(sourceLifecycle = state) }
    }

    fun refreshPermissionState(
        isGranted: Boolean,
        shouldShowRationale: Boolean = false
    ) {
        shouldShowCameraPermissionRationale = shouldShowRationale
        updateUiState { current ->
            val newPermission = if (isGranted) CameraPermissionState.GRANTED else CameraPermissionState.DENIED
            current.copy(
                cameraPermissionState = newPermission,
                hasBindingAttempted = if (isGranted) current.hasBindingAttempted else false
            )
        }
    }

    fun onActivationDecision(decision: ScannerSourceActivationDecision) {
        updateUiState { current ->
            current.copy(
                activationDecision = decision,
                hasBindingAttempted =
                    if (decision.shouldStartBinding) current.hasBindingAttempted else false
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
        syncStuckPreviewTimeout()
    }

    fun onActiveSourceTypeChanged(sourceType: ScannerSourceType) {
        updateUiState { current ->
            current.copy(
                activeSourceType = sourceType,
                hasBindingAttempted =
                    if (current.activeSourceType == sourceType) {
                        current.hasBindingAttempted
                    } else {
                        false
                    }
            )
        }
    }

    fun onPreviewSurfaceStateChanged(
        hasPreviewSurface: Boolean,
        isPreviewVisible: Boolean
    ) {
        updateUiState { current ->
            current.copy(
                hasPreviewSurface = hasPreviewSurface,
                isPreviewVisible = isPreviewVisible
            )
        }
    }

    fun onBindingAttemptChanged(hasBindingAttempted: Boolean) {
        updateUiState { current -> current.copy(hasBindingAttempted = hasBindingAttempted) }
    }

    fun onDecodeDiagnostic(diagnostic: DecodeDiagnostic) {
        val now = System.currentTimeMillis()
        if (
            diagnostic == DecodeDiagnostic.DecodeNoUsableRawValue &&
                now - lastDecodeDiagnosticAtMillis < DECODE_NO_VALUE_DIAGNOSTIC_WINDOW_MS
        ) {
            return
        }
        if (diagnostic == DecodeDiagnostic.DecodeNoUsableRawValue) {
            lastDecodeDiagnosticAtMillis = now
        }
        updateUiState { current ->
            val status =
                when (diagnostic) {
                    DecodeDiagnostic.FrameReceived -> current.scannerDebugStatus
                    DecodeDiagnostic.MediaImageMissing -> "Frame missing media image."
                    DecodeDiagnostic.DecodeFailure -> "Barcode decode failed for current frame."
                    DecodeDiagnostic.DecodeNoUsableRawValue -> "No usable barcode value in current frame."
                    DecodeDiagnostic.DecodeHandoffStarted -> "Decoded value handed to admission pipeline."
                }
            current.copy(scannerDebugStatus = status)
        }
    }

    override fun onCleared() {
        stuckPreviewTimeoutJob?.cancel()
        stuckPreviewTimeoutJob = null
        captureFeedbackClearJob?.cancel()
        captureFeedbackClearJob = null
        timeoutScope.coroutineContext.cancel()
        super.onCleared()
    }

    private companion object {
        const val STUCK_PREVIEW_TIMEOUT_MS: Long = 2_500
        const val STUCK_PREVIEW_STATUS: String = "Camera preview appears stuck. Restart camera to recover."
        const val DECODE_NO_VALUE_DIAGNOSTIC_WINDOW_MS: Long = 3_000
        const val CAPTURE_FEEDBACK_AUTO_CLEAR_MS: Long = 1_500
    }
}
