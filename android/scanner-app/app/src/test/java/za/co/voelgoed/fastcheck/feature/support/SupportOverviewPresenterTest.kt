package za.co.voelgoed.fastcheck.feature.support

import com.google.common.truth.Truth.assertThat
import org.junit.Test
import za.co.voelgoed.fastcheck.core.designsystem.semantic.StatusTone
import za.co.voelgoed.fastcheck.domain.model.EventAttendeeCacheMetrics
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
                ),
                attendeeMetrics = null
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
                ),
                attendeeMetrics = null
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
                ),
                attendeeMetrics = null
            )

        assertThat(uiState.recoveryTone).isEqualTo(StatusTone.Destructive)
        assertThat(uiState.recoveryAction).isEqualTo(SupportRecoveryAction.ReturnToScan)
        assertThat(uiState.recoveryMessage).contains("camera unavailable")
    }

    @Test
    fun unresolvedConflictsSurfaceSupportWarning() {
        val uiState =
            presenter.present(
                scanningUiState = ScanningUiState(),
                attendeeMetrics =
                    EventAttendeeCacheMetrics(
                        cachedAttendeeCount = 120,
                        currentlyInsideCount = 45,
                        attendeesWithRemainingCheckinsCount = 75,
                        activeOverlayCount = 4,
                        unresolvedConflictCount = 2
                    )
            )

        assertThat(uiState.reconciliationTitle).isEqualTo("Reconciliation conflicts active")
        assertThat(uiState.reconciliationTone).isEqualTo(StatusTone.Warning)
        assertThat(uiState.reconciliationMessage).contains("2 attendee conflict")
    }
}
