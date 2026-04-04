package za.co.voelgoed.fastcheck.feature.scanning.ui

import com.google.common.truth.Truth.assertThat
import org.junit.Test
import za.co.voelgoed.fastcheck.app.scanning.ScannerBlockReason
import za.co.voelgoed.fastcheck.app.scanning.ScannerSessionState
import za.co.voelgoed.fastcheck.app.scanning.ScannerSourceActivationDecision
import za.co.voelgoed.fastcheck.core.designsystem.semantic.ScanUiState
import za.co.voelgoed.fastcheck.feature.scanning.domain.CameraPermissionState
import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerSourceState
import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerSourceType
import za.co.voelgoed.fastcheck.feature.scanning.usecase.CaptureHandoffResult
import za.co.voelgoed.fastcheck.feature.scanning.ui.model.ScannerRecoveryState

class ScanningViewModelTest {
    @Test
    fun permissionChangesDriveScannerUiStateWithoutQueueDependencies() {
        val viewModel = ScanningViewModel()

        viewModel.refreshPermissionState(false)
        assertThat(viewModel.uiState.value.cameraPermissionState)
            .isEqualTo(CameraPermissionState.DENIED)
        assertThat(viewModel.uiState.value.isPreviewVisible).isFalse()
        assertThat(viewModel.uiState.value.scannerRecoveryState)
            .isEqualTo(ScannerRecoveryState.RequestPermission(false))

        viewModel.refreshPermissionState(true)
        assertThat(viewModel.uiState.value.cameraPermissionState)
            .isEqualTo(CameraPermissionState.GRANTED)
        assertThat(viewModel.uiState.value.isPreviewVisible).isFalse()
        assertThat(viewModel.uiState.value.scannerStatus).contains("Scanner scaffold ready")
        assertThat(viewModel.uiState.value.scannerRecoveryState)
            .isEqualTo(ScannerRecoveryState.Ready)
    }

    @Test
    fun armedDecisionOnlyBecomesActiveWhenSourceIsReady() {
        val viewModel = ScanningViewModel()

        viewModel.refreshPermissionState(true)
        viewModel.onActivationDecision(
            ScannerSourceActivationDecision(
                shouldStartBinding = true,
                shouldShowCameraPermissionRequest = false,
                sessionState = ScannerSessionState.Armed
            )
        )

        assertThat(viewModel.uiState.value.sessionState).isEqualTo(ScannerSessionState.Armed)
        assertThat(viewModel.uiState.value.isPreviewVisible).isTrue()

        viewModel.onSourceStateChanged(ScannerSourceState.Ready)

        assertThat(viewModel.uiState.value.sessionState).isEqualTo(ScannerSessionState.Active)
        assertThat(viewModel.uiState.value.isSourceReady).isTrue()
        assertThat(viewModel.uiState.value.isPreviewVisible).isTrue()
    }

    @Test
    fun sourceErrorBlocksScannerWithTypedReason() {
        val viewModel = ScanningViewModel()

        viewModel.refreshPermissionState(true)
        viewModel.onActivationDecision(
            ScannerSourceActivationDecision(
                shouldStartBinding = true,
                shouldShowCameraPermissionRequest = false,
                sessionState = ScannerSessionState.Armed
            )
        )

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

        viewModel.onCaptureHandoffResult(CaptureHandoffResult.Accepted)
        assertThat(viewModel.uiState.value.captureSemanticState).isEqualTo(ScanUiState.QueuedLocally)

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
}
