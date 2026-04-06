package za.co.voelgoed.fastcheck.feature.support

import com.google.common.truth.Truth.assertThat
import org.junit.Test
import za.co.voelgoed.fastcheck.core.designsystem.semantic.StatusTone
import za.co.voelgoed.fastcheck.feature.scanning.ui.ScanningUiState
import za.co.voelgoed.fastcheck.feature.scanning.ui.model.ScannerRecoveryState

class SupportOverviewPresenterTest {
    private val presenter = SupportOverviewPresenter()

    @Test
    fun permissionRequestStateMapsToCalmRecoveryAction() {
        val uiState =
            presenter.present(
                ScanningUiState(
                    scannerRecoveryState = ScannerRecoveryState.RequestPermission(false)
                )
            )

        assertThat(uiState.recoveryTitle).isEqualTo("Camera access needed")
        assertThat(uiState.recoveryTone).isEqualTo(StatusTone.Warning)
        assertThat(uiState.recoveryAction).isEqualTo(SupportRecoveryAction.RequestCameraAccess)
    }

    @Test
    fun settingsOnlyStateMapsToAppSettingsAction() {
        val uiState =
            presenter.present(
                ScanningUiState(
                    scannerRecoveryState = ScannerRecoveryState.OpenSystemSettings
                )
            )

        assertThat(uiState.recoveryAction).isEqualTo(SupportRecoveryAction.OpenAppSettings)
        assertThat(uiState.recoveryMessage).contains("Open app settings")
    }

    @Test
    fun sourceErrorMapsToReturnToScanGuidance() {
        val uiState =
            presenter.present(
                ScanningUiState(
                    scannerRecoveryState = ScannerRecoveryState.SourceError("camera unavailable")
                )
            )

        assertThat(uiState.recoveryTone).isEqualTo(StatusTone.Destructive)
        assertThat(uiState.recoveryAction).isEqualTo(SupportRecoveryAction.ReturnToScan)
        assertThat(uiState.recoveryMessage).contains("camera unavailable")
    }
}
