package za.co.voelgoed.fastcheck.feature.scanning.ui

import android.view.LayoutInflater
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.LifecycleRegistry
import androidx.test.core.app.ApplicationProvider
import com.google.common.truth.Truth.assertThat
import java.time.Clock
import java.time.Instant
import java.time.ZoneOffset
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import za.co.voelgoed.fastcheck.databinding.ScannerScreenBinding
import za.co.voelgoed.fastcheck.feature.scanning.camera.CameraPermissionChecker
import za.co.voelgoed.fastcheck.feature.scanning.camera.CameraPermissionState
import za.co.voelgoed.fastcheck.feature.scanning.camera.ScannerCameraBinder
import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerState

@RunWith(RobolectricTestRunner::class)
class ScannerScreenTest {
    private val clock = Clock.fixed(Instant.parse("2026-03-13T08:30:00Z"), ZoneOffset.UTC)

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
                clock
            )
        val screen =
            ScannerScreen(
                binding = binding,
                lifecycleOwner = TestLifecycleOwner(),
                scanningViewModel = viewModel,
                scannerCameraBinder = ScannerCameraBinder(ApplicationProvider.getApplicationContext()),
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

    private class FakeCameraPermissionChecker(
        private val state: CameraPermissionState
    ) : CameraPermissionChecker(ApplicationProvider.getApplicationContext()) {
        override fun currentState(): CameraPermissionState = state
    }

    private class TestLifecycleOwner : LifecycleOwner {
        private val registry = LifecycleRegistry(this).apply {
            currentState = Lifecycle.State.RESUMED
        }

        override val lifecycle: Lifecycle
            get() = registry
    }
}
