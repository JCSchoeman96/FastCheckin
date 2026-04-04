package za.co.voelgoed.fastcheck.feature.support

import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import za.co.voelgoed.fastcheck.feature.diagnostics.DiagnosticsViewModel

@Composable
fun SupportDiagnosticsRoute(
    diagnosticsViewModel: DiagnosticsViewModel,
    modifier: Modifier = Modifier
) {
    val diagnosticsUiState by diagnosticsViewModel.uiState.collectAsState()
    val presenter = remember { SupportDiagnosticsPresenter() }
    val uiState = remember(diagnosticsUiState) { presenter.present(diagnosticsUiState) }

    LaunchedEffect(Unit) {
        diagnosticsViewModel.refresh()
    }

    SupportDiagnosticsScreen(
        uiState = uiState,
        modifier = modifier
    )
}
