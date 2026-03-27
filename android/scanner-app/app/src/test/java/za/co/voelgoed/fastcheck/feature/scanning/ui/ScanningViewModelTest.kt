package za.co.voelgoed.fastcheck.feature.scanning.ui

import com.google.common.truth.Truth.assertThat
import org.junit.Test
import za.co.voelgoed.fastcheck.feature.scanning.domain.CameraPermissionState
import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerSourceState
import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerSourceType

class ScanningViewModelTest {
    @Test
    fun permissionChangesDriveScannerUiStateWithoutQueueDependencies() {
        val viewModel = ScanningViewModel()

        viewModel.refreshPermissionState(false)
        assertThat(viewModel.uiState.value.cameraPermissionState)
            .isEqualTo(CameraPermissionState.DENIED)
        assertThat(viewModel.uiState.value.isPreviewVisible).isFalse()

        viewModel.refreshPermissionState(true)
        assertThat(viewModel.uiState.value.cameraPermissionState)
            .isEqualTo(CameraPermissionState.GRANTED)
        assertThat(viewModel.uiState.value.isPreviewVisible).isFalse()
        assertThat(viewModel.uiState.value.scannerStatus).contains("Scanner scaffold ready")
    }

    @Test
    fun scannerSourceLifecycleDrivesUiStateAndPreviewVisibility() {
        val viewModel = ScanningViewModel()

        // Permission granted but source idle -> no preview
        viewModel.refreshPermissionState(true)
        assertThat(viewModel.uiState.value.cameraPermissionState)
            .isEqualTo(CameraPermissionState.GRANTED)
        assertThat(viewModel.uiState.value.isPreviewVisible).isFalse()
        assertThat(viewModel.uiState.value.isSourceReady).isFalse()

        // Source transitions to Ready -> preview visible
        viewModel.onSourceStateChanged(ScannerSourceState.Ready)
        assertThat(viewModel.uiState.value.sourceLifecycle)
            .isEqualTo(ScannerSourceState.Ready)
        assertThat(viewModel.uiState.value.isSourceReady).isTrue()
        assertThat(viewModel.uiState.value.isPreviewVisible).isTrue()

        // Source error clears readiness and preview
        viewModel.onSourceStateChanged(ScannerSourceState.Error("camera unavailable"))
        assertThat(viewModel.uiState.value.isSourceReady).isFalse()
        assertThat(viewModel.uiState.value.isPreviewVisible).isFalse()
        assertThat(viewModel.uiState.value.sourceErrorMessage).isEqualTo("camera unavailable")
    }

    @Test
    fun stoppingStateShowsCalmRuntimeMessage() {
        val viewModel = ScanningViewModel()

        viewModel.refreshPermissionState(true)
        viewModel.onSourceStateChanged(ScannerSourceState.Stopping)

        assertThat(viewModel.uiState.value.scannerStatus).isEqualTo("Stopping scanner input source.")
        assertThat(viewModel.uiState.value.isPreviewVisible).isFalse()
    }

    @Test
    fun dataWedgeModeDoesNotImplyCameraPermissionOrPreview() {
        val viewModel = ScanningViewModel()

        viewModel.onActiveSourceTypeChanged(ScannerSourceType.BROADCAST_INTENT)
        viewModel.refreshPermissionState(false)
        viewModel.onSourceStateChanged(ScannerSourceState.Ready)

        assertThat(viewModel.uiState.value.isPermissionRequestVisible).isFalse()
        assertThat(viewModel.uiState.value.isPermissionRequestEnabled).isFalse()
        assertThat(viewModel.uiState.value.isPreviewVisible).isFalse()
        assertThat(viewModel.uiState.value.permissionSummary).contains("not required")
        assertThat(viewModel.uiState.value.scannerStatus).contains("Zebra DataWedge scanner ready")
    }

    @Test
    fun permissionRequestStartedRemainsTruthfulForDataWedgeMode() {
        val viewModel = ScanningViewModel()

        viewModel.onActiveSourceTypeChanged(ScannerSourceType.BROADCAST_INTENT)
        viewModel.onPermissionRequestStarted()

        assertThat(viewModel.uiState.value.scannerStatus).contains("not required")
    }
}
