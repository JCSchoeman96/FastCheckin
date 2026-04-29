package za.co.voelgoed.fastcheck.feature.scanning.screen

import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import za.co.voelgoed.fastcheck.app.scanning.ScanPreviewSurfaceHolder
import za.co.voelgoed.fastcheck.domain.model.ScannerSession
import za.co.voelgoed.fastcheck.feature.queue.QueueViewModel
import za.co.voelgoed.fastcheck.feature.scanning.screen.model.ScanOperatorAction
import za.co.voelgoed.fastcheck.feature.scanning.ui.ScanningViewModel
import za.co.voelgoed.fastcheck.feature.sync.SyncViewModel

@Composable
fun ScanDestinationRoute(
    session: ScannerSession,
    scanningViewModel: ScanningViewModel,
    queueViewModel: QueueViewModel,
    syncViewModel: SyncViewModel,
    previewSurfaceHolder: ScanPreviewSurfaceHolder,
    onPreviewSurfaceChanged: () -> Unit,
    onOperatorAction: (ScanOperatorAction) -> Unit,
    modifier: Modifier = Modifier
) {
    val scanningUiState by scanningViewModel.uiState.collectAsState()
    val queueUiState by queueViewModel.uiState.collectAsState()
    val syncUiState by syncViewModel.uiState.collectAsState()
    val currentEventSyncStatus by syncViewModel.currentEventSyncStatus.collectAsState()

    val presenter = remember { ScanDestinationPresenter() }
    val uiState =
        remember(scanningUiState, queueUiState, syncUiState, currentEventSyncStatus) {
            presenter.present(
                session = session,
                scanningUiState = scanningUiState,
                queueUiState = queueUiState,
                syncUiState = syncUiState,
                currentEventSyncStatus = currentEventSyncStatus
            )
        }

    ScanDestinationScreen(
        uiState = uiState,
        previewSurfaceHolder = previewSurfaceHolder,
        onPreviewSurfaceChanged = onPreviewSurfaceChanged,
        onOperatorAction = onOperatorAction,
        modifier = modifier
    )
}
