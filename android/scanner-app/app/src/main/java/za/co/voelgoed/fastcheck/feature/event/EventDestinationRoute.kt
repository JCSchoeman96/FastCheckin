package za.co.voelgoed.fastcheck.feature.event

import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import za.co.voelgoed.fastcheck.domain.model.ScannerSession
import za.co.voelgoed.fastcheck.feature.event.model.EventOperatorAction
import za.co.voelgoed.fastcheck.feature.queue.QueueViewModel
import za.co.voelgoed.fastcheck.feature.sync.SyncViewModel

@Composable
fun EventDestinationRoute(
    session: ScannerSession,
    eventMetricsViewModel: EventMetricsViewModel,
    queueViewModel: QueueViewModel,
    syncViewModel: SyncViewModel,
    onOperatorAction: (EventOperatorAction) -> Unit,
    modifier: Modifier = Modifier
) {
    val attendeeMetrics by eventMetricsViewModel.attendeeMetrics.collectAsStateWithLifecycle()
    val queueUiState by queueViewModel.uiState.collectAsStateWithLifecycle()
    val syncUiState by syncViewModel.uiState.collectAsStateWithLifecycle()
    val currentEventSyncStatus by syncViewModel.currentEventSyncStatus.collectAsStateWithLifecycle()

    LaunchedEffect(session.eventId, session.authenticatedAtEpochMillis) {
        eventMetricsViewModel.observeSession(
            eventId = session.eventId,
            authenticatedAtEpochMillis = session.authenticatedAtEpochMillis
        )
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
        onOperatorAction = onOperatorAction,
        modifier = modifier
    )
}
