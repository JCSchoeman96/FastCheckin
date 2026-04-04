package za.co.voelgoed.fastcheck.feature.support

import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import za.co.voelgoed.fastcheck.feature.scanning.ui.ScanningViewModel

@Composable
fun SupportOverviewRoute(
    scanningViewModel: ScanningViewModel,
    onViewDiagnostics: () -> Unit,
    onRecoveryActionSelected: (SupportRecoveryAction) -> Unit,
    onLogoutRequested: () -> Unit,
    modifier: Modifier = Modifier
) {
    val scanningUiState by scanningViewModel.uiState.collectAsState()
    val presenter = remember { SupportOverviewPresenter() }
    val uiState = remember(scanningUiState) { presenter.present(scanningUiState) }

    SupportOverviewScreen(
        uiState = uiState,
        onRecoveryActionSelected = onRecoveryActionSelected,
        onViewDiagnostics = onViewDiagnostics,
        onLogoutRequested = onLogoutRequested,
        modifier = modifier
    )
}
