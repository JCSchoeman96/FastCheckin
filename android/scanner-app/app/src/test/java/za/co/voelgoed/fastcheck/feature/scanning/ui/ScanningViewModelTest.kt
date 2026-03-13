package za.co.voelgoed.fastcheck.feature.scanning.ui

import androidx.test.core.app.ApplicationProvider
import com.google.common.truth.Truth.assertThat
import java.time.Clock
import java.time.Instant
import java.time.ZoneOffset
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import za.co.voelgoed.fastcheck.feature.scanning.camera.CameraPermissionChecker
import za.co.voelgoed.fastcheck.feature.scanning.camera.CameraPermissionState
import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerCandidate
import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerFeedbackConfig
import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerResult
import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerState

@RunWith(RobolectricTestRunner::class)
class ScanningViewModelTest {
    private val clock = Clock.fixed(Instant.parse("2026-03-13T08:30:00Z"), ZoneOffset.UTC)
    private val feedbackConfig = ScannerFeedbackConfig.default

    @Test
    fun startupPermissionRefreshUsesCheckerAndDeniedStateKeepsPreviewHidden() {
        val viewModel =
            ScanningViewModel(
                ScanningUiStateFactory(),
                FakeCameraPermissionChecker(CameraPermissionState.DENIED),
                clock,
                feedbackConfig
            )

        viewModel.start()

        assertThat(viewModel.uiState.value.cameraPermissionState).isEqualTo(CameraPermissionState.DENIED)
        assertThat(viewModel.uiState.value.isPreviewVisible).isFalse()
        assertThat(viewModel.uiState.value.permissionUiState.visible).isTrue()
        assertThat(viewModel.uiState.value.scannerState)
            .isEqualTo(
                ScannerState.PermissionRequired(
                    permissionState = CameraPermissionState.DENIED,
                    prompt = "Camera permission required before scanner preview can start."
                )
            )
    }

    @Test
    fun grantedPermissionTransitionsIntoInitializingCamera() {
        val viewModel =
            ScanningViewModel(
                ScanningUiStateFactory(),
                FakeCameraPermissionChecker(CameraPermissionState.GRANTED),
                clock,
                feedbackConfig
            )

        viewModel.start()

        assertThat(viewModel.uiState.value.cameraPermissionState).isEqualTo(CameraPermissionState.GRANTED)
        assertThat(viewModel.uiState.value.isPreviewVisible).isTrue()
        assertThat(viewModel.uiState.value.permissionUiState.visible).isFalse()
        assertThat(viewModel.uiState.value.scannerState).isEqualTo(ScannerState.InitializingCamera)
        assertThat(viewModel.uiState.value.scannerStatus).contains("Preparing camera preview")
    }

    @Test
    fun scannerUiStateWrapsFsmAndOverlayModels() {
        val viewModel =
            ScanningViewModel(
                ScanningUiStateFactory(),
                FakeCameraPermissionChecker(CameraPermissionState.DENIED),
                clock,
                feedbackConfig
            )
        val candidate = ScannerCandidate("VG-5", 10L)

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

    @Test
    fun cooldownUsesInjectedScannerFeedbackConfig() {
        val viewModel =
            ScanningViewModel(
                ScanningUiStateFactory(),
                FakeCameraPermissionChecker(CameraPermissionState.GRANTED),
                clock,
                ScannerFeedbackConfig(resultCooldownMillis = 2_400L)
            )
        val candidate = ScannerCandidate("VG-55", 10L)

        viewModel.onCooldownStarted(ScannerResult.ReplaySuppressed(candidate))

        val cooldownState = viewModel.uiState.value.scannerState as ScannerState.Cooldown
        assertThat(cooldownState.cooldown.endsAtEpochMillis).isEqualTo(clock.millis() + 2_400L)
    }

    @Test
    fun cameraBindFailureStaysScannerLocal() {
        val viewModel =
            ScanningViewModel(
                ScanningUiStateFactory(),
                FakeCameraPermissionChecker(CameraPermissionState.GRANTED),
                clock,
                feedbackConfig
            )

        viewModel.start()
        viewModel.onScannerBindingFailed("Preview unavailable")

        assertThat(viewModel.uiState.value.isPreviewVisible).isTrue()
        assertThat(viewModel.uiState.value.scannerState)
            .isEqualTo(
                ScannerState.Seeking(
                    lastResult = ScannerResult.InitializationFailure("Preview unavailable")
                )
            )
    }

    private class FakeCameraPermissionChecker(
        private val state: CameraPermissionState
    ) : CameraPermissionChecker(ApplicationProvider.getApplicationContext()) {
        override fun currentState(): CameraPermissionState = state
    }
}
