package za.co.voelgoed.fastcheck.feature.event

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import za.co.voelgoed.fastcheck.core.designsystem.components.FcBanner
import za.co.voelgoed.fastcheck.core.designsystem.components.FcCard
import za.co.voelgoed.fastcheck.core.designsystem.components.FcStatusChip
import za.co.voelgoed.fastcheck.core.designsystem.theme.fastCheck
import za.co.voelgoed.fastcheck.feature.event.model.EventOperatorAction

@Composable
fun EventDestinationScreen(
    uiState: EventDestinationUiState,
    onOperatorAction: (EventOperatorAction) -> Unit,
    modifier: Modifier = Modifier
) {
    val spacing = MaterialTheme.fastCheck.spacing

    Column(
        modifier = modifier,
        verticalArrangement = Arrangement.spacedBy(spacing.medium)
    ) {
        FcCard(modifier = Modifier.fillMaxWidth()) {
            Column(verticalArrangement = Arrangement.spacedBy(spacing.small)) {
                Text(
                    text = uiState.headerTitle,
                    style = MaterialTheme.typography.headlineSmall
                )
                Text(
                    text = uiState.headerSubtitle,
                    style = MaterialTheme.typography.bodyMedium
                )
                FcStatusChip(
                    text = uiState.statusChip.text,
                    tone = uiState.statusChip.tone
                )
                Text(
                    text = uiState.statusMessage,
                    style = MaterialTheme.typography.bodyMedium
                )
            }
        }

        uiState.attentionBanner?.let { banner ->
            FcBanner(
                title = banner.title,
                message = banner.message,
                tone = banner.tone,
                modifier = Modifier.fillMaxWidth()
            )
        }

        if (uiState.operatorActions.isNotEmpty()) {
            FcCard(modifier = Modifier.fillMaxWidth()) {
                Column(verticalArrangement = Arrangement.spacedBy(spacing.small)) {
                    Text(
                        text = "Recovery actions",
                        style = MaterialTheme.typography.titleMedium
                    )
                    Text(
                        text = "Use these when the event overview shows sync or upload issues.",
                        style = MaterialTheme.typography.bodyMedium
                    )
                    uiState.operatorActions.forEach { actionUi ->
                        TextButton(onClick = { onOperatorAction(actionUi.action) }) {
                            Text(text = actionUi.label)
                        }
                    }
                }
            }
        }

        EventSectionCard(
            section = uiState.attendeeSection,
            modifier = Modifier.fillMaxWidth()
        )

        EventSectionCard(
            section = uiState.queueSection,
            modifier = Modifier.fillMaxWidth()
        )

        EventSectionCard(
            section = uiState.activitySection,
            modifier = Modifier.fillMaxWidth()
        )
    }
}

@Composable
private fun EventSectionCard(
    section: EventSectionUiModel,
    modifier: Modifier = Modifier
) {
    val spacing = MaterialTheme.fastCheck.spacing

    FcCard(modifier = modifier) {
        Column(verticalArrangement = Arrangement.spacedBy(spacing.small)) {
            Text(
                text = section.title,
                style = MaterialTheme.typography.titleMedium
            )
            Text(
                text = section.supportingText,
                style = MaterialTheme.typography.bodyMedium
            )
            section.metrics.forEach { metric ->
                EventMetricRow(metric = metric)
            }
        }
    }
}

@Composable
private fun EventMetricRow(metric: EventMetricUiModel) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.SpaceBetween
    ) {
        Text(
            text = metric.label,
            style = MaterialTheme.typography.bodyMedium
        )
        Text(
            text = metric.value,
            style = MaterialTheme.typography.bodyMedium,
            fontWeight = FontWeight.SemiBold
        )
    }
}
