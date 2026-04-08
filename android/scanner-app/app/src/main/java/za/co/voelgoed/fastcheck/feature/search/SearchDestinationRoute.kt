package za.co.voelgoed.fastcheck.feature.search

import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import za.co.voelgoed.fastcheck.domain.model.ScannerSession
import za.co.voelgoed.fastcheck.feature.sync.SyncViewModel

@Composable
fun SearchDestinationRoute(
    session: ScannerSession,
    searchViewModel: SearchViewModel,
    syncViewModel: SyncViewModel
) {
    val query by searchViewModel.queryState.collectAsStateWithLifecycle()
    val results by searchViewModel.results.collectAsStateWithLifecycle()
    val selectedDetail by searchViewModel.selectedDetail.collectAsStateWithLifecycle()
    val manualActionUiState by searchViewModel.manualActionUiState.collectAsStateWithLifecycle()
    val currentEventSyncStatus by syncViewModel.currentEventSyncStatus.collectAsStateWithLifecycle()

    LaunchedEffect(session.eventId, session.authenticatedAtEpochMillis) {
        searchViewModel.observeSession(session.eventId, session.authenticatedAtEpochMillis)
    }

    val presenter = remember { SearchDestinationPresenter() }
    val uiState =
        remember(query, results, selectedDetail, currentEventSyncStatus, manualActionUiState, session.eventId) {
            presenter.present(
                eventId = session.eventId,
                query = query,
                results = results,
                selectedDetail = selectedDetail,
                syncStatus = currentEventSyncStatus,
                manualActionUiState = manualActionUiState
            )
        }

    SearchDestinationScreen(
        uiState = uiState,
        onQueryChanged = searchViewModel::onQueryChanged,
        onSelectAttendee = searchViewModel::selectAttendee,
        onClear = searchViewModel::clearSearch,
        onBack = searchViewModel::navigateBackToResults,
        onManualAdmit = searchViewModel::admitSelectedAttendee
    )
}
