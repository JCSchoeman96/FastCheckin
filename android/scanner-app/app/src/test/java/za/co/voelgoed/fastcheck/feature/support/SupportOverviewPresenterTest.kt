package za.co.voelgoed.fastcheck.feature.support

import com.google.common.truth.Truth.assertThat
import org.junit.Test
import za.co.voelgoed.fastcheck.core.designsystem.semantic.StatusTone
import za.co.voelgoed.fastcheck.core.designsystem.semantic.SyncUiState
import za.co.voelgoed.fastcheck.domain.model.EventAttendeeCacheMetrics
import za.co.voelgoed.fastcheck.feature.queue.QueueUiState
import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerSourceType
import za.co.voelgoed.fastcheck.feature.scanning.ui.ScanningUiState
import za.co.voelgoed.fastcheck.feature.scanning.ui.model.ScannerRecoveryState
import za.co.voelgoed.fastcheck.feature.support.model.SupportOperationalAction
import za.co.voelgoed.fastcheck.feature.sync.SyncScreenUiState

class SupportOverviewPresenterTest {
    private val presenter = SupportOverviewPresenter()

    private fun present(
        scanningUiState: ScanningUiState,
        attendeeMetrics: EventAttendeeCacheMetrics? = null,
        queueUiState: QueueUiState = QueueUiState(),
        syncUiState: SyncScreenUiState = SyncScreenUiState()
    ): SupportOverviewUiState =
        presenter.present(
            scanningUiState = scanningUiState,
            attendeeMetrics = attendeeMetrics,
            queueUiState = queueUiState,
            syncUiState = syncUiState
        )

    @Test
    fun permissionRequestStateMapsToCalmRecoveryAction() {
        val uiState =
            present(
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
            present(
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
            present(
                ScanningUiState(
                    scannerRecoveryState = ScannerRecoveryState.SourceError("camera unavailable")
                )
            )

        assertThat(uiState.recoveryTone).isEqualTo(StatusTone.Destructive)
        assertThat(uiState.recoveryAction).isEqualTo(SupportRecoveryAction.ReturnToScan)
        assertThat(uiState.recoveryMessage).contains("camera unavailable")
    }

    @Test
    fun startingRecoveryMapsToStartupInProgress() {
        val uiState =
            present(
                ScanningUiState(
                    scannerRecoveryState = ScannerRecoveryState.Starting
                )
            )

        assertThat(uiState.recoveryTitle).isEqualTo("Scanner startup in progress")
        assertThat(uiState.recoveryTone).isEqualTo(StatusTone.Info)
        assertThat(uiState.recoveryAction).isEqualTo(SupportRecoveryAction.ReturnToScan)
    }

    @Test
    fun inactiveRecoveryMapsToScannerInactiveGuidance() {
        val uiState =
            present(
                ScanningUiState(
                    scannerRecoveryState = ScannerRecoveryState.Inactive
                )
            )

        assertThat(uiState.recoveryTitle).isEqualTo("Scanner inactive")
        assertThat(uiState.recoveryTone).isEqualTo(StatusTone.Neutral)
        assertThat(uiState.recoveryAction).isEqualTo(SupportRecoveryAction.ReturnToScan)
    }

    @Test
    fun unresolvedConflictsSurfaceSupportWarning() {
        val uiState =
            present(
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

    @Test
    fun operationalRetryHiddenWhenQueueEmpty() {
        val uiState =
            present(
                scanningUiState = ScanningUiState(),
                queueUiState = QueueUiState(localQueueDepth = 0),
                syncUiState = SyncScreenUiState()
            )

        assertThat(uiState.operationalActions.map { it.action })
            .doesNotContain(SupportOperationalAction.RetryUpload)
    }

    @Test
    fun operationalReloginWhenAuthExpiredWithBacklog() {
        val uiState =
            present(
                scanningUiState = ScanningUiState(),
                queueUiState =
                    QueueUiState(
                        localQueueDepth = 2,
                        uploadSemanticState = SyncUiState.Failed(reason = "Auth expired")
                    ),
                syncUiState = SyncScreenUiState()
            )

        assertThat(uiState.operationalActions.map { it.action })
            .contains(SupportOperationalAction.Relogin)
        assertThat(uiState.operationalActions.map { it.action })
            .doesNotContain(SupportOperationalAction.RetryUpload)
    }

    @Test
    fun operationalManualSyncHiddenWhileSyncing() {
        val uiState =
            present(
                scanningUiState = ScanningUiState(),
                syncUiState = SyncScreenUiState(isSyncing = true)
            )

        assertThat(uiState.operationalActions.map { it.action })
            .doesNotContain(SupportOperationalAction.ManualSync)
    }

    @Test
    fun uploadQuarantineSurfacesSeparateNoticeWithoutImplyingLogoutFixesIt() {
        val uiState =
            present(
                scanningUiState = ScanningUiState(),
                queueUiState = QueueUiState(quarantineCount = 3)
            )

        assertThat(uiState.uploadQuarantineNotice).isNotNull()
        assertThat(uiState.uploadQuarantineNotice).contains("3")
        assertThat(uiState.uploadQuarantineNotice).contains("upload quarantine")
        assertThat(uiState.sessionMessage).doesNotContain("Diagnostics")
        assertThat(uiState.sessionMessage).contains("not required to clear")
    }

    @Test
    fun readyRecoveryMapsToScannerAccessReadyWithoutWorkaroundBranch() {
        val uiState =
            present(
                ScanningUiState(
                    activeSourceType = ScannerSourceType.CAMERA,
                    scannerRecoveryState = ScannerRecoveryState.Ready
                )
            )

        assertThat(uiState.recoveryTitle).isEqualTo("Scanner access ready")
        assertThat(uiState.recoveryMessage).contains("smartphone scanning")
        assertThat(uiState.recoveryTone).isEqualTo(StatusTone.Success)
    }
}
