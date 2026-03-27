package za.co.voelgoed.fastcheck.app.scanning

import com.google.common.truth.Truth.assertThat
import org.junit.Test

class ScannerSourceActivationPolicyTest {
    private val policy = ScannerSourceActivationPolicy()

    @Test
    fun cameraModeRequiresPermissionBeforeStartingBinding() {
        val decision =
            policy.evaluate(
                sourceMode = ScannerShellSourceMode.CAMERA,
                hasCameraPermission = false,
                isShellStarted = true
            )

        assertThat(decision.shouldStartBinding).isFalse()
        assertThat(decision.shouldShowCameraPermissionRequest).isTrue()
    }

    @Test
    fun dataWedgeModeDoesNotGateBindingOnCameraPermission() {
        val decision =
            policy.evaluate(
                sourceMode = ScannerShellSourceMode.DATAWEDGE,
                hasCameraPermission = false,
                isShellStarted = true
            )

        assertThat(decision.shouldStartBinding).isTrue()
        assertThat(decision.shouldShowCameraPermissionRequest).isFalse()
    }

    @Test
    fun dataWedgeModeDoesNotStartBeforeShellIsStarted() {
        val decision =
            policy.evaluate(
                sourceMode = ScannerShellSourceMode.DATAWEDGE,
                hasCameraPermission = false,
                isShellStarted = false
            )

        assertThat(decision.shouldStartBinding).isFalse()
        assertThat(decision.shouldShowCameraPermissionRequest).isFalse()
    }
}
