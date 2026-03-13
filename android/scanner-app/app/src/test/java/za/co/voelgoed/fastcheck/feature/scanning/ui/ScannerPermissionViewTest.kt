package za.co.voelgoed.fastcheck.feature.scanning.ui

import android.view.LayoutInflater
import androidx.test.core.app.ApplicationProvider
import com.google.common.truth.Truth.assertThat
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import za.co.voelgoed.fastcheck.databinding.ScannerPermissionViewBinding

@RunWith(RobolectricTestRunner::class)
class ScannerPermissionViewTest {
    @Test
    fun rendersPermissionStateAndTriggersRequestCallback() {
        var requestTriggered = false
        val binding =
            ScannerPermissionViewBinding.inflate(
                LayoutInflater.from(ApplicationProvider.getApplicationContext())
            )
        val view =
            ScannerPermissionView(binding) {
                requestTriggered = true
            }

        view.render(
            ScannerPermissionUiState(
                visible = true,
                headline = "Camera permission",
                message = "Camera permission required before scanner preview can start.",
                requestButtonLabel = "Request Camera Permission",
                isRequestEnabled = true
            )
        )
        binding.requestCameraPermissionButton.performClick()

        assertThat(binding.scannerPermissionRoot.visibility).isEqualTo(android.view.View.VISIBLE)
        assertThat(binding.scannerPermissionMessage.text.toString())
            .isEqualTo("Camera permission required before scanner preview can start.")
        assertThat(requestTriggered).isTrue()
    }
}
