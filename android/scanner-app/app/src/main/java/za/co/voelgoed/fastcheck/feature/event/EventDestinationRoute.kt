package za.co.voelgoed.fastcheck.feature.event

import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import za.co.voelgoed.fastcheck.domain.model.ScannerSession
import za.co.voelgoed.fastcheck.feature.queue.QueueViewModel
import za.co.voelgoed.fastcheck.feature.sync.SyncViewModel

@Composable
fun EventDestinationRoute(
    session: ScannerSession,
    eventMetricsViewModel: EventMetricsViewModel,
    queueViewModel: QueueViewModel,
    syncViewModel: SyncViewModel,
    modifier: Modifier = Modifier
) {
    val attendeeMetrics by eventMetricsViewModel.attendeeMetrics.collectAsState()
    val queueUiState by queueViewModel.uiState.collectAsState()
    val syncUiState by syncViewModel.uiState.collectAsState()
    val currentEventSyncStatus by syncViewModel.currentEventSyncStatus.collectAsState()

    LaunchedEffect(session.eventId, session.authenticatedAtEpochMillis) {
        eventMetricsViewModel.observeSession(
            eventId = session.eventId,
            authenticatedAtEpochMillis = session.authenticatedAtEpochMillis
        )
        syncViewModel.refreshCurrentEventSyncStatus()
        syncViewModel.ensureBootstrapSyncForEvent(session.eventId)
    }

    val presenter = remember { EventDestinationPresenter() }
    val uiState =
        remember(session, queueUiState, syncUiState, currentEventSyncStatus, attendeeMetrics) {
            presenter.present(
                session = session,
                queueUiState = queueUiState,
                syncUiState = syncUiState,
                currentEventSyncStatus = currentEventSyncStatus,
                attendeeMetrics = attendeeMetrics
            )
        }

    EventDestinationScreen(
        uiState = uiState,
        modifier = modifier
    )
}
