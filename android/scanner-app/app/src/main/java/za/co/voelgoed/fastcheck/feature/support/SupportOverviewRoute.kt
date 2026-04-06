package za.co.voelgoed.fastcheck.feature.support

import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import za.co.voelgoed.fastcheck.domain.model.ScannerSession
import za.co.voelgoed.fastcheck.feature.event.EventMetricsViewModel
import za.co.voelgoed.fastcheck.feature.queue.QueueViewModel
import za.co.voelgoed.fastcheck.feature.scanning.ui.ScanningViewModel
import za.co.voelgoed.fastcheck.feature.support.model.SupportOperationalAction
import za.co.voelgoed.fastcheck.feature.sync.SyncViewModel

@Composable
fun SupportOverviewRoute(
    session: ScannerSession?,
    eventMetricsViewModel: EventMetricsViewModel,
    scanningViewModel: ScanningViewModel,
    queueViewModel: QueueViewModel,
    syncViewModel: SyncViewModel,
    onViewDiagnostics: () -> Unit,
    onRecoveryActionSelected: (SupportRecoveryAction) -> Unit,
    onOperationalAction: (SupportOperationalAction) -> Unit,
    onLogoutRequested: () -> Unit,
    modifier: Modifier = Modifier
) {
    val scanningUiState by scanningViewModel.uiState.collectAsStateWithLifecycle()
    val queueUiState by queueViewModel.uiState.collectAsStateWithLifecycle()
    val syncUiState by syncViewModel.uiState.collectAsStateWithLifecycle()
    LaunchedEffect(session?.eventId, session?.authenticatedAtEpochMillis) {
        session?.let {
            eventMetricsViewModel.observeSession(it.eventId, it.authenticatedAtEpochMillis)
        }
    }
    val attendeeMetrics by eventMetricsViewModel.attendeeMetrics.collectAsStateWithLifecycle()
    val presenter = remember { SupportOverviewPresenter() }
    val uiState =
        remember(scanningUiState, attendeeMetrics, queueUiState, syncUiState) {
            presenter.present(
                scanningUiState = scanningUiState,
                attendeeMetrics = attendeeMetrics,
                queueUiState = queueUiState,
                syncUiState = syncUiState
            )
        }

    SupportOverviewScreen(
        uiState = uiState,
        onRecoveryActionSelected = onRecoveryActionSelected,
        onOperationalAction = onOperationalAction,
        onViewDiagnostics = onViewDiagnostics,
        onLogoutRequested = onLogoutRequested,
        modifier = modifier
    )
}
