package za.co.voelgoed.fastcheck.feature.support

import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import za.co.voelgoed.fastcheck.domain.model.ScannerSession
import za.co.voelgoed.fastcheck.feature.event.EventMetricsViewModel
import za.co.voelgoed.fastcheck.feature.scanning.ui.ScanningViewModel

@Composable
fun SupportOverviewRoute(
    session: ScannerSession?,
    eventMetricsViewModel: EventMetricsViewModel,
    scanningViewModel: ScanningViewModel,
    onViewDiagnostics: () -> Unit,
    onRecoveryActionSelected: (SupportRecoveryAction) -> Unit,
    onLogoutRequested: () -> Unit,
    modifier: Modifier = Modifier
) {
    val scanningUiState by scanningViewModel.uiState.collectAsStateWithLifecycle()
    LaunchedEffect(session?.eventId, session?.authenticatedAtEpochMillis) {
        session?.let {
            eventMetricsViewModel.observeSession(it.eventId, it.authenticatedAtEpochMillis)
        }
    }
    val attendeeMetrics by eventMetricsViewModel.attendeeMetrics.collectAsStateWithLifecycle()
    val presenter = remember { SupportOverviewPresenter() }
    val uiState = remember(scanningUiState, attendeeMetrics) { presenter.present(scanningUiState, attendeeMetrics) }

    SupportOverviewScreen(
        uiState = uiState,
        onRecoveryActionSelected = onRecoveryActionSelected,
        onViewDiagnostics = onViewDiagnostics,
        onLogoutRequested = onLogoutRequested,
        modifier = modifier
    )
}
