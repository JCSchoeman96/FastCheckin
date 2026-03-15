package za.co.voelgoed.fastcheck.feature.scanning.ui

import android.view.LayoutInflater
import androidx.camera.core.ImageAnalysis
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.LifecycleRegistry
import androidx.test.core.app.ApplicationProvider
import com.google.common.truth.Truth.assertThat
import java.time.Clock
import java.time.Instant
import java.time.ZoneOffset
import kotlinx.coroutines.flow.MutableSharedFlow
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import za.co.voelgoed.fastcheck.databinding.ScannerScreenBinding
import za.co.voelgoed.fastcheck.feature.scanning.camera.CameraPermissionChecker
import za.co.voelgoed.fastcheck.feature.scanning.camera.CameraPermissionState
import za.co.voelgoed.fastcheck.feature.scanning.camera.ScannerCameraBinder
import za.co.voelgoed.fastcheck.feature.scanning.camera.ScannerCameraConfig
import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerFeedbackConfig
import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerResult
import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerState
import za.co.voelgoed.fastcheck.feature.scanning.usecase.ScannerLoopController
import za.co.voelgoed.fastcheck.feature.scanning.usecase.ScannerLoopEvent

@RunWith(RobolectricTestRunner::class)
class ScannerScreenTest {
    private val clock = Clock.fixed(Instant.parse("2026-03-13T08:30:00Z"), ZoneOffset.UTC)
    private val feedbackConfig = ScannerFeedbackConfig.default

    @Test
    fun renderTogglesPreviewVisibilityAndStatusText() {
        val binding =
            ScannerScreenBinding.inflate(
                LayoutInflater.from(ApplicationProvider.getApplicationContext())
            )
        val viewModel =
            ScanningViewModel(
                ScanningUiStateFactory(),
                FakeCameraPermissionChecker(CameraPermissionState.DENIED),
                clock,
                feedbackConfig,
                FakeScannerLoopController()
            )
        val binder = ScannerCameraBinder(ApplicationProvider.getApplicationContext(), ScannerCameraConfig.default)
        val screen =
            ScannerScreen(
                binding = binding,
                lifecycleOwner = TestLifecycleOwner(),
                scanningViewModel = viewModel,
                scannerCameraBinder = binder,
                scannerAnalyzer = NoOpAnalyzer(),
                onLaunchPermissionRequest = {}
            )

        screen.render(
            ScanningUiState(
                scannerState =
                    ScannerState.PermissionRequired(
                        permissionState = CameraPermissionState.DENIED,
                        prompt = "Camera permission required before scanner preview can start."
                    ),
                cameraPermissionState = CameraPermissionState.DENIED,
                permissionUiState =
                    ScannerPermissionUiState(
                        visible = true,
                        headline = "Camera permission",
                        message = "Camera permission required before scanner preview can start.",
                        requestButtonLabel = "Request Camera Permission",
                        isRequestEnabled = true
                    ),
                scannerStatus = "Camera permission required before scanner preview can start.",
                isPreviewVisible = false
            )
        )

        assertThat(binding.scannerPreview.visibility).isEqualTo(android.view.View.GONE)
        assertThat(binding.scannerStatusValue.text.toString())
            .isEqualTo("Camera permission required before scanner preview can start.")

        screen.render(
            ScanningUiState(
                scannerState = ScannerState.Seeking(),
                cameraPermissionState = CameraPermissionState.GRANTED,
                permissionUiState =
                    ScannerPermissionUiState(
                        visible = false,
                        headline = "Camera permission",
                        message = "Camera permission granted.",
                        requestButtonLabel = "Request Camera Permission",
                        isRequestEnabled = false
                    ),
                scannerStatus = "Point the camera at a ticket QR code.",
                isPreviewVisible = true
            )
        )

        assertThat(binding.scannerPreview.visibility).isEqualTo(android.view.View.VISIBLE)
        assertThat(binding.scannerStatusValue.text.toString())
            .isEqualTo("Point the camera at a ticket QR code.")
    }

    @Test
    fun renderInitializingCameraTriggersAnalyzerBindingPath() {
        val binding =
            ScannerScreenBinding.inflate(
                LayoutInflater.from(ApplicationProvider.getApplicationContext())
            )
        val viewModel =
            ScanningViewModel(
                ScanningUiStateFactory(),
                FakeCameraPermissionChecker(CameraPermissionState.GRANTED),
                clock,
                feedbackConfig,
                FakeScannerLoopController()
            )
        val binder = FakeScannerCameraBinder()
        val screen =
            ScannerScreen(
                binding = binding,
                lifecycleOwner = TestLifecycleOwner(),
                scanningViewModel = viewModel,
                scannerCameraBinder = binder,
                scannerAnalyzer = NoOpAnalyzer(),
                onLaunchPermissionRequest = {}
            )

        screen.render(
            ScanningUiState(
                scannerState = ScannerState.InitializingCamera,
                cameraPermissionState = CameraPermissionState.GRANTED,
                permissionUiState =
                    ScannerPermissionUiState(
                        visible = false,
                        headline = "Camera permission",
                        message = "Camera permission granted.",
                        requestButtonLabel = "Request Camera Permission",
                        isRequestEnabled = false
                    ),
                scannerStatus = "Preparing camera preview.",
                isPreviewVisible = true
            )
        )

        assertThat(binder.bindCalls).isEqualTo(1)
        assertThat(binder.lastAnalyzer).isNotNull()
        assertThat(viewModel.uiState.value.scannerState).isEqualTo(ScannerState.Seeking())
    }

    @Test
    fun renderInitializingCameraPropagatesCameraBindingFailureAsScannerLocalError() {
        val binding =
            ScannerScreenBinding.inflate(
                LayoutInflater.from(ApplicationProvider.getApplicationContext())
            )
        val viewModel =
            ScanningViewModel(
                ScanningUiStateFactory(),
                FakeCameraPermissionChecker(CameraPermissionState.GRANTED),
                clock,
                feedbackConfig,
                FakeScannerLoopController()
            )
        val binder = FakeScannerCameraBinder(failureMessage = "Camera unavailable")
        val screen =
            ScannerScreen(
                binding = binding,
                lifecycleOwner = TestLifecycleOwner(),
                scanningViewModel = viewModel,
                scannerCameraBinder = binder,
                scannerAnalyzer = NoOpAnalyzer(),
                onLaunchPermissionRequest = {}
            )

        screen.render(
            ScanningUiState(
                scannerState = ScannerState.InitializingCamera,
                cameraPermissionState = CameraPermissionState.GRANTED,
                permissionUiState =
                    ScannerPermissionUiState(
                        visible = false,
                        headline = "Camera permission",
                        message = "Camera permission granted.",
                        requestButtonLabel = "Request Camera Permission",
                        isRequestEnabled = false
                    ),
                scannerStatus = "Preparing camera preview.",
                isPreviewVisible = true
            )
        )

        assertThat(binder.bindCalls).isEqualTo(1)
        assertThat(viewModel.uiState.value.scannerState)
            .isEqualTo(
                ScannerState.Seeking(
                    lastResult = ScannerResult.InitializationFailure("Camera unavailable")
                )
            )
    }

    private class FakeCameraPermissionChecker(
        private val state: CameraPermissionState
    ) : CameraPermissionChecker(ApplicationProvider.getApplicationContext()) {
        override fun currentState(): CameraPermissionState = state
    }

    private class FakeScannerLoopController : ScannerLoopController {
        override val events = MutableSharedFlow<ScannerLoopEvent>(replay = 1, extraBufferCapacity = 8)

        override fun reset() = Unit

        override fun onCooldownComplete() = Unit
    }

    private class FakeScannerCameraBinder(
        private val failureMessage: String? = null
    ) : ScannerCameraBinder(ApplicationProvider.getApplicationContext(), ScannerCameraConfig.default) {
        var bindCalls: Int = 0
        var lastAnalyzer: ImageAnalysis.Analyzer? = null

        override fun bindPreview(
            lifecycleOwner: LifecycleOwner,
            previewView: androidx.camera.view.PreviewView,
            onBound: () -> Unit,
            onError: (Throwable) -> Unit
        ) = error("Preview-only binding should not be used once live analyzer runtime is active.")

        override fun bind(
            lifecycleOwner: LifecycleOwner,
            previewView: androidx.camera.view.PreviewView,
            analyzer: ImageAnalysis.Analyzer?,
            onBound: (za.co.voelgoed.fastcheck.feature.scanning.camera.ScannerCameraBinding) -> Unit,
            onError: (Throwable) -> Unit
        ) {
            bindCalls += 1
            lastAnalyzer = analyzer

            if (failureMessage != null) {
                onError(IllegalStateException(failureMessage))
            } else {
                onBound(
                    za.co.voelgoed.fastcheck.feature.scanning.camera.ScannerCameraBinding(
                        config = ScannerCameraConfig.default,
                        hasImageAnalysis = analyzer != null
                    )
                )
            }
        }
    }

    private class NoOpAnalyzer : ImageAnalysis.Analyzer {
        override fun analyze(image: androidx.camera.core.ImageProxy) = Unit
    }

    private class TestLifecycleOwner : LifecycleOwner {
        private val registry = LifecycleRegistry(this).apply {
            currentState = Lifecycle.State.RESUMED
        }

        override val lifecycle: Lifecycle
            get() = registry
    }
}
