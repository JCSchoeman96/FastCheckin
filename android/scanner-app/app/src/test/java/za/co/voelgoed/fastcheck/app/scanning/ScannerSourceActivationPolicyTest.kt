package za.co.voelgoed.fastcheck.app.scanning

import com.google.common.truth.Truth.assertThat
import org.junit.Test

class ScannerSourceActivationPolicyTest {
    private val policy = ScannerSourceActivationPolicy()

    @Test
    fun cameraModeRequiresPermissionBeforeStartingBinding() {
        val decision =
            policy.evaluate(
                ScannerActivationContext(
                    sourceMode = ScannerShellSourceMode.CAMERA,
                    isAuthenticated = true,
                    isScanDestinationSelected = true,
                    isForeground = true,
                    hasCameraPermission = false,
                    hasPreviewSurface = true,
                    isPreviewVisible = true
                )
            )

        assertThat(decision.shouldStartBinding).isFalse()
        assertThat(decision.shouldShowCameraPermissionRequest).isTrue()
        assertThat(decision.sessionState)
            .isEqualTo(ScannerSessionState.Blocked(ScannerBlockReason.PermissionDenied))
    }

    @Test
    fun dataWedgeModeArmsWhenScanTabIsForegrounded() {
        val decision =
            policy.evaluate(
                ScannerActivationContext(
                    sourceMode = ScannerShellSourceMode.DATAWEDGE,
                    isAuthenticated = true,
                    isScanDestinationSelected = true,
                    isForeground = true,
                    hasCameraPermission = false,
                    hasPreviewSurface = false,
                    isPreviewVisible = false
                )
            )

        assertThat(decision.shouldStartBinding).isTrue()
        assertThat(decision.shouldShowCameraPermissionRequest).isFalse()
        assertThat(decision.sessionState).isEqualTo(ScannerSessionState.Armed)
    }

    @Test
    fun backgroundedScanBlocksBinding() {
        val decision =
            policy.evaluate(
                ScannerActivationContext(
                    sourceMode = ScannerShellSourceMode.CAMERA,
                    isAuthenticated = true,
                    isScanDestinationSelected = true,
                    isForeground = false,
                    hasCameraPermission = true,
                    hasPreviewSurface = true,
                    isPreviewVisible = true
                )
            )

        assertThat(decision.shouldStartBinding).isFalse()
        assertThat(decision.sessionState)
            .isEqualTo(ScannerSessionState.Blocked(ScannerBlockReason.Backgrounded))
    }

    @Test
    fun missingPreviewBlocksCameraBinding() {
        val decision =
            policy.evaluate(
                ScannerActivationContext(
                    sourceMode = ScannerShellSourceMode.CAMERA,
                    isAuthenticated = true,
                    isScanDestinationSelected = true,
                    isForeground = true,
                    hasCameraPermission = true,
                    hasPreviewSurface = false,
                    isPreviewVisible = false
                )
            )

        assertThat(decision.shouldStartBinding).isFalse()
        assertThat(decision.sessionState)
            .isEqualTo(ScannerSessionState.Blocked(ScannerBlockReason.PreviewUnavailable))
    }

    @Test
    fun attachedButNotVisiblePreviewBlocksCameraBinding() {
        val decision =
            policy.evaluate(
                ScannerActivationContext(
                    sourceMode = ScannerShellSourceMode.CAMERA,
                    isAuthenticated = true,
                    isScanDestinationSelected = true,
                    isForeground = true,
                    hasCameraPermission = true,
                    hasPreviewSurface = true,
                    isPreviewVisible = false
                )
            )

        assertThat(decision.shouldStartBinding).isFalse()
        assertThat(decision.shouldShowCameraPermissionRequest).isFalse()
        assertThat(decision.sessionState)
            .isEqualTo(ScannerSessionState.Blocked(ScannerBlockReason.PreviewNotVisible))
    }

    @Test
    fun visiblePreviewArmsCameraBinding() {
        val decision =
            policy.evaluate(
                ScannerActivationContext(
                    sourceMode = ScannerShellSourceMode.CAMERA,
                    isAuthenticated = true,
                    isScanDestinationSelected = true,
                    isForeground = true,
                    hasCameraPermission = true,
                    hasPreviewSurface = true,
                    isPreviewVisible = true
                )
            )

        assertThat(decision.shouldStartBinding).isTrue()
        assertThat(decision.shouldShowCameraPermissionRequest).isFalse()
        assertThat(decision.sessionState).isEqualTo(ScannerSessionState.Armed)
    }

    @Test
    fun previewUnavailableAndPreviewNotVisibleAreDistinctBlockReasons() {
        val noSurface =
            policy.evaluate(
                ScannerActivationContext(
                    sourceMode = ScannerShellSourceMode.CAMERA,
                    isAuthenticated = true,
                    isScanDestinationSelected = true,
                    isForeground = true,
                    hasCameraPermission = true,
                    hasPreviewSurface = false,
                    isPreviewVisible = false
                )
            )

        val attachedNotVisible =
            policy.evaluate(
                ScannerActivationContext(
                    sourceMode = ScannerShellSourceMode.CAMERA,
                    isAuthenticated = true,
                    isScanDestinationSelected = true,
                    isForeground = true,
                    hasCameraPermission = true,
                    hasPreviewSurface = true,
                    isPreviewVisible = false
                )
            )

        assertThat(noSurface.sessionState)
            .isEqualTo(ScannerSessionState.Blocked(ScannerBlockReason.PreviewUnavailable))
        assertThat(attachedNotVisible.sessionState)
            .isEqualTo(ScannerSessionState.Blocked(ScannerBlockReason.PreviewNotVisible))
        assertThat(noSurface.sessionState).isNotEqualTo(attachedNotVisible.sessionState)
    }

    @Test
    fun leavingScanTabReturnsIdle() {
        val decision =
            policy.evaluate(
                ScannerActivationContext(
                    sourceMode = ScannerShellSourceMode.CAMERA,
                    isAuthenticated = true,
                    isScanDestinationSelected = false,
                    isForeground = true,
                    hasCameraPermission = true,
                    hasPreviewSurface = true,
                    isPreviewVisible = true
                )
            )

        assertThat(decision.shouldStartBinding).isFalse()
        assertThat(decision.sessionState).isEqualTo(ScannerSessionState.Idle)
    }
}
