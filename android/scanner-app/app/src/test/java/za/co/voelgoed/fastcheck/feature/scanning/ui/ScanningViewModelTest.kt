package za.co.voelgoed.fastcheck.feature.scanning.ui

import com.google.common.truth.Truth.assertThat
import org.junit.Test
import za.co.voelgoed.fastcheck.feature.scanning.domain.CameraPermissionState

class ScanningViewModelTest {
    @Test
    fun permissionChangesDriveScannerUiStateWithoutQueueDependencies() {
        val viewModel = ScanningViewModel()

        viewModel.refreshPermissionState(false)
        assertThat(viewModel.uiState.value.cameraPermissionState).isEqualTo(CameraPermissionState.DENIED)
        assertThat(viewModel.uiState.value.isPreviewVisible).isFalse()

        viewModel.refreshPermissionState(true)
        assertThat(viewModel.uiState.value.cameraPermissionState).isEqualTo(CameraPermissionState.GRANTED)
        assertThat(viewModel.uiState.value.isPreviewVisible).isTrue()
        assertThat(viewModel.uiState.value.scannerStatus).contains("Preparing scanner preview")
    }
}
