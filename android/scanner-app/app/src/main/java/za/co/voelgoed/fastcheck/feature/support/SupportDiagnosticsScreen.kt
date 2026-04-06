package za.co.voelgoed.fastcheck.feature.support

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import za.co.voelgoed.fastcheck.core.designsystem.components.FcBanner
import za.co.voelgoed.fastcheck.core.designsystem.components.FcCard
import za.co.voelgoed.fastcheck.core.designsystem.semantic.StatusTone
import za.co.voelgoed.fastcheck.core.designsystem.theme.fastCheck

@Composable
fun SupportDiagnosticsScreen(
    uiState: SupportDiagnosticsUiState,
    modifier: Modifier = Modifier
) {
    val spacing = MaterialTheme.fastCheck.spacing

    Column(
        modifier = modifier,
        verticalArrangement = Arrangement.spacedBy(spacing.medium)
    ) {
        FcBanner(
            title = "Diagnostics",
            message = "Diagnostics stays secondary and support-focused. It is grouped here instead of living in the main operator flow.",
            tone = StatusTone.Neutral,
            modifier = Modifier.fillMaxWidth()
        )

        uiState.sections.forEach { section ->
            FcCard(modifier = Modifier.fillMaxWidth()) {
                Column(verticalArrangement = Arrangement.spacedBy(spacing.small)) {
                    Text(
                        text = section.title,
                        style = MaterialTheme.typography.titleMedium
                    )
                    section.items.forEach { item ->
                        Column(verticalArrangement = Arrangement.spacedBy(spacing.xSmall)) {
                            Text(
                                text = item.label,
                                style = MaterialTheme.typography.labelLarge
                            )
                            Text(
                                text = item.value,
                                style = MaterialTheme.typography.bodyMedium
                            )
                        }
                    }
                }
            }
        }
    }
}
