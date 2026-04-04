package za.co.voelgoed.fastcheck.feature.support

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import za.co.voelgoed.fastcheck.core.designsystem.components.FcBanner
import za.co.voelgoed.fastcheck.core.designsystem.components.FcCard
import za.co.voelgoed.fastcheck.core.designsystem.theme.fastCheck

@Composable
fun SupportOverviewScreen(
    uiState: SupportOverviewUiState,
    onRecoveryActionSelected: (SupportRecoveryAction) -> Unit,
    onViewDiagnostics: () -> Unit,
    onLogoutRequested: () -> Unit,
    modifier: Modifier = Modifier
) {
    val spacing = MaterialTheme.fastCheck.spacing

    Column(
        modifier = modifier,
        verticalArrangement = Arrangement.spacedBy(spacing.medium)
    ) {
        FcBanner(
            title = "Support",
            message = "Support stays available without taking over the main operator flow.",
            tone = uiState.recoveryTone,
            modifier = Modifier.fillMaxWidth()
        )

        FcCard(modifier = Modifier.fillMaxWidth()) {
            Column(verticalArrangement = Arrangement.spacedBy(spacing.small)) {
                Text(
                    text = "Scanner recovery",
                    style = MaterialTheme.typography.titleMedium
                )
                Text(
                    text = uiState.recoveryTitle,
                    style = MaterialTheme.typography.bodyLarge
                )
                Text(
                    text = uiState.recoveryMessage,
                    style = MaterialTheme.typography.bodyMedium
                )
                uiState.recoveryAction?.let { action ->
                    TextButton(onClick = { onRecoveryActionSelected(action) }) {
                        Text(text = action.label)
                    }
                }
            }
        }

        FcCard(modifier = Modifier.fillMaxWidth()) {
            Column(verticalArrangement = Arrangement.spacedBy(spacing.small)) {
                Text(
                    text = "Diagnostics",
                    style = MaterialTheme.typography.titleMedium
                )
                Text(
                    text = uiState.diagnosticsMessage,
                    style = MaterialTheme.typography.bodyMedium
                )
                TextButton(onClick = onViewDiagnostics) {
                    Text(text = "View diagnostics")
                }
            }
        }

        FcCard(modifier = Modifier.fillMaxWidth()) {
            Column(verticalArrangement = Arrangement.spacedBy(spacing.small)) {
                Text(
                    text = "Session",
                    style = MaterialTheme.typography.titleMedium
                )
                Text(
                    text = uiState.sessionMessage,
                    style = MaterialTheme.typography.bodyMedium
                )
                TextButton(onClick = onLogoutRequested) {
                    Text(text = "Log out")
                }
            }
        }
    }
}
