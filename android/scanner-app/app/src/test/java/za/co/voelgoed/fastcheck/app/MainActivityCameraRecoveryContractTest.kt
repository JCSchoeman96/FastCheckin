package za.co.voelgoed.fastcheck.app

import com.google.common.truth.Truth.assertThat
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import za.co.voelgoed.fastcheck.app.scanning.ScannerShellSourceMode
import za.co.voelgoed.fastcheck.feature.scanning.ui.model.ScannerRecoveryState

@RunWith(RobolectricTestRunner::class)
class MainActivityCameraRecoveryContractTest {
    @Test
    fun cameraScanEntryAutoRequestsWhenPermissionIsMissingAndRequestable() {
        val shouldAutoRequest =
            shouldAutoRequestCameraPermissionOnScanEntry(
                sourceMode = ScannerShellSourceMode.CAMERA,
                isAuthenticated = true,
                isScanDestinationSelected = true,
                isForeground = true,
                hasCameraPermission = false,
                shouldShowCameraPermissionRequest = true,
                recoveryState = ScannerRecoveryState.RequestPermission(false),
                hasAutoRequestedCameraPermissionThisScanEntry = false
            )

        assertThat(shouldAutoRequest).isTrue()
    }

    @Test
    fun autoRequestDoesNotRepeatWithinSameScanEntry() {
        val shouldAutoRequest =
            shouldAutoRequestCameraPermissionOnScanEntry(
                sourceMode = ScannerShellSourceMode.CAMERA,
                isAuthenticated = true,
                isScanDestinationSelected = true,
                isForeground = true,
                hasCameraPermission = false,
                shouldShowCameraPermissionRequest = true,
                recoveryState = ScannerRecoveryState.RequestPermission(false),
                hasAutoRequestedCameraPermissionThisScanEntry = true
            )

        assertThat(shouldAutoRequest).isFalse()
    }

    @Test
    fun autoRequestDoesNotFireForSettingsOnlyRecovery() {
        val shouldAutoRequest =
            shouldAutoRequestCameraPermissionOnScanEntry(
                sourceMode = ScannerShellSourceMode.CAMERA,
                isAuthenticated = true,
                isScanDestinationSelected = true,
                isForeground = true,
                hasCameraPermission = false,
                shouldShowCameraPermissionRequest = true,
                recoveryState = ScannerRecoveryState.OpenSystemSettings,
                hasAutoRequestedCameraPermissionThisScanEntry = false
            )

        assertThat(shouldAutoRequest).isFalse()
    }

    @Test
    fun autoRequestDoesNotFireForDataWedge() {
        val shouldAutoRequest =
            shouldAutoRequestCameraPermissionOnScanEntry(
                sourceMode = ScannerShellSourceMode.DATAWEDGE,
                isAuthenticated = true,
                isScanDestinationSelected = true,
                isForeground = true,
                hasCameraPermission = false,
                shouldShowCameraPermissionRequest = false,
                recoveryState = ScannerRecoveryState.CameraNotRequired,
                hasAutoRequestedCameraPermissionThisScanEntry = false
            )

        assertThat(shouldAutoRequest).isFalse()
    }

    @Test
    fun appSettingsIntentTargetsThisPackage() {
        val intent = appSettingsIntent("za.co.voelgoed.fastcheck")

        assertThat(intent.action).isEqualTo(android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
        assertThat(intent.dataString).isEqualTo("package:za.co.voelgoed.fastcheck")
    }
}
