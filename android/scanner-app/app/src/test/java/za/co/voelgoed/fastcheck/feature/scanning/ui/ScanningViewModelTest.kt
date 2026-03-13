package za.co.voelgoed.fastcheck.feature.scanning.ui

import com.google.common.truth.Truth.assertThat
import java.time.Clock
import java.time.Instant
import java.time.ZoneOffset
import org.junit.Test
import za.co.voelgoed.fastcheck.feature.scanning.domain.CameraPermissionState
import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerCandidate
import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerResult
import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerState

class ScanningViewModelTest {
    private val clock = Clock.fixed(Instant.parse("2026-03-13T08:30:00Z"), ZoneOffset.UTC)

    @Test
    fun permissionChangesDriveScannerUiStateWithoutQueueDependencies() {
        val viewModel = ScanningViewModel(ScanningUiStateFactory(), clock)

        viewModel.refreshPermissionState(false)
        assertThat(viewModel.uiState.value.cameraPermissionState).isEqualTo(CameraPermissionState.DENIED)
        assertThat(viewModel.uiState.value.isPreviewVisible).isFalse()
        assertThat(viewModel.uiState.value.scannerState)
            .isEqualTo(
                ScannerState.PermissionRequired(
                    permissionState = CameraPermissionState.DENIED,
                    prompt = "Camera permission required before scanner preview can start."
                )
            )
    }

    @Test
    fun scannerUiStateWrapsFsmAndOverlayModels() {
        val viewModel = ScanningViewModel(ScanningUiStateFactory(), clock)
        val candidate = ScannerCandidate("VG-5", 10L)

        viewModel.refreshPermissionState(true)
        assertThat(viewModel.uiState.value.cameraPermissionState).isEqualTo(CameraPermissionState.GRANTED)
        assertThat(viewModel.uiState.value.isPreviewVisible).isTrue()
        assertThat(viewModel.uiState.value.scannerState).isEqualTo(ScannerState.InitializingCamera)
        assertThat(viewModel.uiState.value.scannerStatus).contains("Preparing camera preview")

        viewModel.onCandidateDetected(candidate)
        assertThat(viewModel.uiState.value.scannerState)
            .isEqualTo(ScannerState.CandidateDetected(candidate))

        viewModel.onProcessingStarted(candidate)
        assertThat(viewModel.uiState.value.scannerState)
            .isEqualTo(ScannerState.ProcessingLock(candidate))

        viewModel.onImmediateResult(ScannerResult.ReplaySuppressed(candidate))
        assertThat(viewModel.uiState.value.scannerState)
            .isEqualTo(ScannerState.ReplaySuppressed(ScannerResult.ReplaySuppressed(candidate)))

        viewModel.onCooldownStarted(ScannerResult.ReplaySuppressed(candidate))
        assertThat(viewModel.uiState.value.scannerState)
            .isInstanceOf(ScannerState.Cooldown::class.java)
        assertThat(viewModel.uiState.value.overlayModel.cooldownRemainingMillis).isEqualTo(1_500L)
    }
}
