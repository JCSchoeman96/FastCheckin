package za.co.voelgoed.fastcheck.feature.scanning.ui

import androidx.test.core.app.ApplicationProvider
import com.google.common.truth.Truth.assertThat
import java.time.Clock
import java.time.Instant
import java.time.ZoneOffset
import kotlinx.coroutines.flow.MutableSharedFlow
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import za.co.voelgoed.fastcheck.feature.scanning.camera.CameraPermissionChecker
import za.co.voelgoed.fastcheck.feature.scanning.camera.CameraPermissionState
import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerCandidate
import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerFeedbackConfig
import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerResult
import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerState
import za.co.voelgoed.fastcheck.feature.scanning.usecase.ScannerLoopController
import za.co.voelgoed.fastcheck.feature.scanning.usecase.ScannerLoopEvent

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
                feedbackConfig,
                FakeScannerLoopController()
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
                feedbackConfig,
                FakeScannerLoopController()
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
        val loopController = FakeScannerLoopController()
        val viewModel =
            ScanningViewModel(
                ScanningUiStateFactory(),
                FakeCameraPermissionChecker(CameraPermissionState.DENIED),
                clock,
                feedbackConfig,
                loopController
            )
        val candidate = ScannerCandidate("VG-5", 10L)

        loopController.tryEmit(ScannerLoopEvent.CandidateAccepted(candidate))
        assertThat(viewModel.uiState.value.scannerState)
            .isEqualTo(ScannerState.CandidateDetected(candidate))

        loopController.tryEmit(ScannerLoopEvent.ProcessingStarted(candidate))
        assertThat(viewModel.uiState.value.scannerState)
            .isEqualTo(ScannerState.ProcessingLock(candidate))

        loopController.tryEmit(ScannerLoopEvent.ImmediateResult(ScannerResult.ReplaySuppressed(candidate)))
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
                ScannerFeedbackConfig(resultCooldownMillis = 2_400L),
                FakeScannerLoopController()
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
                feedbackConfig,
                FakeScannerLoopController()
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

    private class FakeScannerLoopController : ScannerLoopController {
        private val mutableEvents = MutableSharedFlow<ScannerLoopEvent>(replay = 1, extraBufferCapacity = 8)
        var resetCalls: Int = 0
        var cooldownCompleteCalls: Int = 0

        override val events = mutableEvents

        override fun reset() {
            resetCalls += 1
        }

        override fun onCooldownComplete() {
            cooldownCompleteCalls += 1
        }

        fun tryEmit(event: ScannerLoopEvent) {
            mutableEvents.tryEmit(event)
        }
    }
}
