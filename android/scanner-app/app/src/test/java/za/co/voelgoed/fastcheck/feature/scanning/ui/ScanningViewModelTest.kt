package za.co.voelgoed.fastcheck.feature.scanning.ui

import com.google.common.truth.Truth.assertThat
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runTest
import org.junit.Test
import za.co.voelgoed.fastcheck.app.scanning.ScannerBlockReason
import za.co.voelgoed.fastcheck.app.scanning.ScannerSessionState
import za.co.voelgoed.fastcheck.app.scanning.ScannerSourceActivationDecision
import za.co.voelgoed.fastcheck.core.common.AppDispatchers
import za.co.voelgoed.fastcheck.core.designsystem.semantic.ScanUiState
import za.co.voelgoed.fastcheck.feature.scanning.analysis.DecodeDiagnostic
import za.co.voelgoed.fastcheck.feature.scanning.domain.CameraPermissionState
import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerSourceState
import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerSourceType
import za.co.voelgoed.fastcheck.feature.scanning.ui.model.ScannerRecoveryState
import za.co.voelgoed.fastcheck.feature.scanning.usecase.CaptureHandoffResult

class ScanningViewModelTest {
    @Test
    fun stuckPreviewRequiresTimeoutAndShowsRestartRecovery() = runTest {
        val dispatcher = StandardTestDispatcher(testScheduler)
        val viewModel = ScanningViewModel(AppDispatchers(main = dispatcher), stuckPreviewTimeoutMs = 2_500)

        viewModel.onActiveSourceTypeChanged(ScannerSourceType.CAMERA)
        viewModel.refreshPermissionState(isGranted = true)
        viewModel.onActivationDecision(
            ScannerSourceActivationDecision(
                shouldStartBinding = true,
                shouldShowCameraPermissionRequest = false,
                sessionState = ScannerSessionState.Armed
            )
        )
        viewModel.onPreviewSurfaceStateChanged(
            hasPreviewSurface = true,
            isPreviewVisible = false
        )
        viewModel.onBindingAttemptChanged(true)
        viewModel.onSourceStateChanged(ScannerSourceState.Starting)

        advanceTimeBy(2_400)
        assertThat(viewModel.uiState.value.scannerRecoveryState)
            .isNotEqualTo(ScannerRecoveryState.StuckPreview)

        advanceTimeBy(200)
        assertThat(viewModel.uiState.value.scannerRecoveryState)
            .isEqualTo(ScannerRecoveryState.StuckPreview)
        assertThat(viewModel.uiState.value.scannerStatus)
            .isEqualTo("Camera preview appears stuck. Restart camera to recover.")
    }

    @Test
    fun stuckPreviewClearsWhenPreviewBecomesVisible() = runTest {
        val dispatcher = StandardTestDispatcher(testScheduler)
        val viewModel = ScanningViewModel(AppDispatchers(main = dispatcher), stuckPreviewTimeoutMs = 2_500)

        viewModel.onActiveSourceTypeChanged(ScannerSourceType.CAMERA)
        viewModel.refreshPermissionState(isGranted = true)
        viewModel.onActivationDecision(
            ScannerSourceActivationDecision(
                shouldStartBinding = true,
                shouldShowCameraPermissionRequest = false,
                sessionState = ScannerSessionState.Armed
            )
        )
        viewModel.onPreviewSurfaceStateChanged(
            hasPreviewSurface = true,
            isPreviewVisible = false
        )
        viewModel.onBindingAttemptChanged(true)
        viewModel.onSourceStateChanged(ScannerSourceState.Ready)
        advanceTimeBy(2_600)
        assertThat(viewModel.uiState.value.scannerRecoveryState)
            .isEqualTo(ScannerRecoveryState.StuckPreview)

        viewModel.onPreviewSurfaceStateChanged(
            hasPreviewSurface = true,
            isPreviewVisible = true
        )
        assertThat(viewModel.uiState.value.scannerRecoveryState)
            .isEqualTo(ScannerRecoveryState.Ready)
    }

    @Test
    fun grantedPermissionOnActiveScanSurfaceDoesNotImmediatelyMarkScannerRecoveryReady() {
        val viewModel = ScanningViewModel()

        viewModel.onActiveSourceTypeChanged(ScannerSourceType.CAMERA)
        viewModel.refreshPermissionState(isGranted = true)
        viewModel.onActivationDecision(
            ScannerSourceActivationDecision(
                shouldStartBinding = true,
                shouldShowCameraPermissionRequest = false,
                sessionState = ScannerSessionState.Armed
            )
        )

        assertThat(viewModel.uiState.value.cameraPermissionState)
            .isEqualTo(CameraPermissionState.GRANTED)
        assertThat(viewModel.uiState.value.scannerRecoveryState)
            .isEqualTo(ScannerRecoveryState.Starting)
        assertThat(viewModel.uiState.value.shouldHostPreviewSurface).isTrue()
        assertThat(viewModel.uiState.value.hasPreviewSurface).isFalse()
        assertThat(viewModel.uiState.value.hasBindingAttempted).isFalse()
    }

    @Test
    fun previewVisibilityIsHolderDrivenNotSessionDriven() {
        val viewModel = ScanningViewModel()

        viewModel.onActiveSourceTypeChanged(ScannerSourceType.CAMERA)
        viewModel.refreshPermissionState(isGranted = true)
        viewModel.onActivationDecision(
            ScannerSourceActivationDecision(
                shouldStartBinding = true,
                shouldShowCameraPermissionRequest = false,
                sessionState = ScannerSessionState.Armed
            )
        )

        assertThat(viewModel.uiState.value.isPreviewVisible).isFalse()

        viewModel.onPreviewSurfaceStateChanged(
            hasPreviewSurface = true,
            isPreviewVisible = true
        )

        assertThat(viewModel.uiState.value.isPreviewVisible).isTrue()
    }

    @Test
    fun bindingAttemptAndSourceReadyDriveRecoveryProgression() {
        val viewModel = ScanningViewModel()

        viewModel.onActiveSourceTypeChanged(ScannerSourceType.CAMERA)
        viewModel.refreshPermissionState(isGranted = true)
        viewModel.onActivationDecision(
            ScannerSourceActivationDecision(
                shouldStartBinding = true,
                shouldShowCameraPermissionRequest = false,
                sessionState = ScannerSessionState.Armed
            )
        )
        viewModel.onPreviewSurfaceStateChanged(
            hasPreviewSurface = true,
            isPreviewVisible = false
        )
        viewModel.onBindingAttemptChanged(true)
        viewModel.onSourceStateChanged(ScannerSourceState.Starting)

        assertThat(viewModel.uiState.value.scannerRecoveryState)
            .isEqualTo(ScannerRecoveryState.Starting)

        viewModel.onSourceStateChanged(ScannerSourceState.Ready)

        assertThat(viewModel.uiState.value.scannerRecoveryState)
            .isEqualTo(ScannerRecoveryState.Ready)
        assertThat(viewModel.uiState.value.isSourceReady).isTrue()
    }

    @Test
    fun sourceReadyWithPreviewNotVisibleStaysTruthful() {
        val viewModel = ScanningViewModel()

        viewModel.onActiveSourceTypeChanged(ScannerSourceType.CAMERA)
        viewModel.refreshPermissionState(isGranted = true)
        viewModel.onActivationDecision(
            ScannerSourceActivationDecision(
                shouldStartBinding = true,
                shouldShowCameraPermissionRequest = false,
                sessionState = ScannerSessionState.Armed
            )
        )
        viewModel.onPreviewSurfaceStateChanged(
            hasPreviewSurface = true,
            isPreviewVisible = false
        )
        viewModel.onBindingAttemptChanged(true)
        viewModel.onSourceStateChanged(ScannerSourceState.Ready)

        assertThat(viewModel.uiState.value.scannerRecoveryState)
            .isEqualTo(ScannerRecoveryState.Ready)
        assertThat(viewModel.uiState.value.scannerStatus)
            .isEqualTo("Scanner ready. Preview is still becoming visible in the UI.")
        assertThat(viewModel.uiState.value.scannerStatus).doesNotContain("confirmed")
    }

    @Test
    fun bindingAttemptResetsOnStopOrPermissionLoss() {
        val viewModel = ScanningViewModel()

        viewModel.onActiveSourceTypeChanged(ScannerSourceType.CAMERA)
        viewModel.refreshPermissionState(isGranted = true)
        viewModel.onActivationDecision(
            ScannerSourceActivationDecision(
                shouldStartBinding = true,
                shouldShowCameraPermissionRequest = false,
                sessionState = ScannerSessionState.Armed
            )
        )
        viewModel.onBindingAttemptChanged(true)

        assertThat(viewModel.uiState.value.hasBindingAttempted).isTrue()

        viewModel.onActivationDecision(
            ScannerSourceActivationDecision(
                shouldStartBinding = false,
                shouldShowCameraPermissionRequest = false,
                sessionState = ScannerSessionState.Blocked(ScannerBlockReason.Backgrounded)
            )
        )

        assertThat(viewModel.uiState.value.hasBindingAttempted).isFalse()

        viewModel.onActivationDecision(
            ScannerSourceActivationDecision(
                shouldStartBinding = true,
                shouldShowCameraPermissionRequest = false,
                sessionState = ScannerSessionState.Armed
            )
        )
        viewModel.onBindingAttemptChanged(true)
        viewModel.refreshPermissionState(isGranted = false)

        assertThat(viewModel.uiState.value.hasBindingAttempted).isFalse()
    }

    @Test
    fun grantedPermissionOutsideActiveScanSurfaceDoesNotReportStarting() {
        val viewModel = ScanningViewModel()

        viewModel.onActiveSourceTypeChanged(ScannerSourceType.CAMERA)
        viewModel.refreshPermissionState(isGranted = true)
        viewModel.onActivationDecision(
            ScannerSourceActivationDecision(
                shouldStartBinding = false,
                shouldShowCameraPermissionRequest = false,
                sessionState = ScannerSessionState.Blocked(ScannerBlockReason.Backgrounded)
            )
        )

        assertThat(viewModel.uiState.value.shouldHostPreviewSurface).isFalse()
        assertThat(viewModel.uiState.value.scannerRecoveryState)
            .isEqualTo(ScannerRecoveryState.Inactive)
    }

    @Test
    fun permissionRequestStartedPreservesExplicitRequestingStatus() {
        val viewModel = ScanningViewModel()

        viewModel.onActiveSourceTypeChanged(ScannerSourceType.CAMERA)
        viewModel.refreshPermissionState(isGranted = false)
        viewModel.onPermissionRequestStarted()

        assertThat(viewModel.uiState.value.scannerStatus)
            .isEqualTo("Requesting camera permission for scanner input.")
    }

    @Test
    fun sourceErrorBlocksScannerWithTypedReason() {
        val viewModel = ScanningViewModel()

        viewModel.onActiveSourceTypeChanged(ScannerSourceType.CAMERA)
        viewModel.refreshPermissionState(isGranted = true)
        viewModel.onActivationDecision(
            ScannerSourceActivationDecision(
                shouldStartBinding = true,
                shouldShowCameraPermissionRequest = false,
                sessionState = ScannerSessionState.Armed
            )
        )
        viewModel.onBindingAttemptChanged(true)

        viewModel.onSourceStateChanged(ScannerSourceState.Error("camera unavailable"))

        assertThat(viewModel.uiState.value.sessionState)
            .isEqualTo(ScannerSessionState.Blocked(ScannerBlockReason.SourceError))
        assertThat(viewModel.uiState.value.sourceErrorMessage).isEqualTo("camera unavailable")
        assertThat(viewModel.uiState.value.isPreviewVisible).isFalse()
        assertThat(viewModel.uiState.value.scannerRecoveryState)
            .isEqualTo(ScannerRecoveryState.SourceError("camera unavailable"))
    }

    @Test
    fun captureResultsMapToSemanticTruth() {
        val viewModel = ScanningViewModel()

        viewModel.onCaptureHandoffResult(
            CaptureHandoffResult.Accepted(
                attendeeId = 7L,
                displayName = "Jane Doe",
                ticketCode = "VG-007",
                idempotencyKey = "idem-7",
                scannedAt = "2026-04-02T09:00:00Z"
            )
        )
        assertThat(viewModel.uiState.value.captureSemanticState).isEqualTo(ScanUiState.AcceptedLocal)

        viewModel.onCaptureHandoffResult(CaptureHandoffResult.SuppressedByCooldown)
        assertThat(viewModel.uiState.value.captureSemanticState).isEqualTo(ScanUiState.Suppressed)

        viewModel.onCaptureHandoffResult(CaptureHandoffResult.Failed("Queue failed"))
        assertThat(viewModel.uiState.value.captureSemanticState)
            .isEqualTo(ScanUiState.Failed("Queue failed"))
    }

    @Test
    fun dataWedgeModeDoesNotImplyCameraPermissionOrPreview() {
        val viewModel = ScanningViewModel()

        viewModel.onActiveSourceTypeChanged(ScannerSourceType.BROADCAST_INTENT)
        viewModel.onActivationDecision(
            ScannerSourceActivationDecision(
                shouldStartBinding = true,
                shouldShowCameraPermissionRequest = false,
                sessionState = ScannerSessionState.Armed
            )
        )
        viewModel.onSourceStateChanged(ScannerSourceState.Ready)

        assertThat(viewModel.uiState.value.isPermissionRequestVisible).isFalse()
        assertThat(viewModel.uiState.value.isPermissionRequestEnabled).isFalse()
        assertThat(viewModel.uiState.value.isPreviewVisible).isFalse()
        assertThat(viewModel.uiState.value.permissionSummary).contains("not required")
        assertThat(viewModel.uiState.value.sessionState).isEqualTo(ScannerSessionState.Active)
        assertThat(viewModel.uiState.value.scannerRecoveryState)
            .isEqualTo(ScannerRecoveryState.CameraNotRequired)
    }

    @Test
    fun dataWedgeModeNeverTransitionsToStuckPreview() = runTest {
        val dispatcher = StandardTestDispatcher(testScheduler)
        val viewModel = ScanningViewModel(AppDispatchers(main = dispatcher), stuckPreviewTimeoutMs = 2_500)

        viewModel.onActiveSourceTypeChanged(ScannerSourceType.BROADCAST_INTENT)
        viewModel.onActivationDecision(
            ScannerSourceActivationDecision(
                shouldStartBinding = true,
                shouldShowCameraPermissionRequest = false,
                sessionState = ScannerSessionState.Armed
            )
        )
        viewModel.onBindingAttemptChanged(true)
        viewModel.onSourceStateChanged(ScannerSourceState.Starting)

        advanceTimeBy(3_000)
        assertThat(viewModel.uiState.value.scannerRecoveryState)
            .isEqualTo(ScannerRecoveryState.CameraNotRequired)
    }

    @Test
    fun permanentlyDeniedCameraPermissionMovesRecoveryToSettings() {
        val viewModel = ScanningViewModel()

        viewModel.onPermissionRequestStarted()
        viewModel.refreshPermissionState(
            isGranted = false,
            shouldShowRationale = false
        )

        assertThat(viewModel.uiState.value.scannerRecoveryState)
            .isEqualTo(ScannerRecoveryState.OpenSystemSettings)
    }

    @Test
    fun deniedCameraPermissionWithRationaleRemainsRequestable() {
        val viewModel = ScanningViewModel()

        viewModel.onPermissionRequestStarted()
        viewModel.refreshPermissionState(
            isGranted = false,
            shouldShowRationale = true
        )

        assertThat(viewModel.uiState.value.scannerRecoveryState)
            .isEqualTo(ScannerRecoveryState.RequestPermission(true))
    }

    @Test
    fun previewNotVisibleShowsTransientStatusText() {
        val viewModel = ScanningViewModel()

        viewModel.onActiveSourceTypeChanged(ScannerSourceType.CAMERA)
        viewModel.refreshPermissionState(isGranted = true)
        viewModel.onActivationDecision(
            ScannerSourceActivationDecision(
                shouldStartBinding = false,
                shouldShowCameraPermissionRequest = false,
                sessionState = ScannerSessionState.Blocked(ScannerBlockReason.PreviewNotVisible)
            )
        )

        assertThat(viewModel.uiState.value.scannerStatus)
            .isEqualTo("Camera preview is becoming visible. Scanner will start automatically.")
        assertThat(viewModel.uiState.value.scannerStatus)
            .doesNotContain("Preparing the scan preview")
    }

    @Test
    fun previewHostStaysMountedUnderPreviewNotVisible() {
        val viewModel = ScanningViewModel()

        viewModel.onActiveSourceTypeChanged(ScannerSourceType.CAMERA)
        viewModel.refreshPermissionState(isGranted = true)
        viewModel.onActivationDecision(
            ScannerSourceActivationDecision(
                shouldStartBinding = false,
                shouldShowCameraPermissionRequest = false,
                sessionState = ScannerSessionState.Blocked(ScannerBlockReason.PreviewNotVisible)
            )
        )

        assertThat(viewModel.uiState.value.shouldHostPreviewSurface).isTrue()
    }

    @Test
    fun decodeDiagnosticFailureSetsDebugStatus() {
        val viewModel = ScanningViewModel()

        viewModel.onDecodeDiagnostic(DecodeDiagnostic.DecodeFailure)

        assertThat(viewModel.uiState.value.scannerDebugStatus)
            .isEqualTo("Barcode decode failed for current frame.")
    }

    @Test
    fun decodeNoUsableRawValueDiagnosticIsRateLimited() {
        val viewModel = ScanningViewModel()

        viewModel.onDecodeDiagnostic(DecodeDiagnostic.DecodeNoUsableRawValue)
        val first = viewModel.uiState.value.scannerDebugStatus

        viewModel.onDecodeDiagnostic(DecodeDiagnostic.FrameReceived)
        viewModel.onDecodeDiagnostic(DecodeDiagnostic.DecodeNoUsableRawValue)
        val second = viewModel.uiState.value.scannerDebugStatus

        assertThat(first).isEqualTo("No usable barcode value in current frame.")
        assertThat(second).isEqualTo("No usable barcode value in current frame.")
    }

    @Test
    fun previewNotVisibleRecoveryStateIsTransientNotError() {
        val viewModel = ScanningViewModel()

        viewModel.onActiveSourceTypeChanged(ScannerSourceType.CAMERA)
        viewModel.refreshPermissionState(isGranted = true)
        viewModel.onActivationDecision(
            ScannerSourceActivationDecision(
                shouldStartBinding = false,
                shouldShowCameraPermissionRequest = false,
                sessionState = ScannerSessionState.Blocked(ScannerBlockReason.PreviewNotVisible)
            )
        )

        assertThat(viewModel.uiState.value.scannerRecoveryState)
            .isEqualTo(ScannerRecoveryState.Starting)
        assertThat(viewModel.uiState.value.scannerRecoveryState)
            .isNotInstanceOf(ScannerRecoveryState.SourceError::class.java)
    }
}
