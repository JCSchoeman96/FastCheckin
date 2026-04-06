package za.co.voelgoed.fastcheck.feature.search

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import za.co.voelgoed.fastcheck.core.designsystem.components.FcBanner
import za.co.voelgoed.fastcheck.core.designsystem.components.FcCard
import za.co.voelgoed.fastcheck.core.designsystem.components.FcStatusChip
import za.co.voelgoed.fastcheck.core.designsystem.theme.fastCheck
import za.co.voelgoed.fastcheck.feature.search.detail.AttendeeDetailScreen
import za.co.voelgoed.fastcheck.feature.search.model.SearchResultRowUiModel
import za.co.voelgoed.fastcheck.feature.search.model.SearchUiState

@Composable
fun SearchDestinationScreen(
    uiState: SearchUiState,
    onQueryChanged: (String) -> Unit,
    onSelectAttendee: (Long) -> Unit,
    onClear: () -> Unit,
    onBack: () -> Unit,
    onManualAdmit: () -> Unit,
    modifier: Modifier = Modifier
) {
    val spacing = MaterialTheme.fastCheck.spacing

    Column(
        modifier = modifier,
        verticalArrangement = Arrangement.spacedBy(spacing.medium)
    ) {
        OutlinedTextField(
            value = uiState.query,
            onValueChange = onQueryChanged,
            modifier = Modifier.fillMaxWidth(),
            label = { Text("Search attendees") },
            placeholder = { Text("Ticket, name, or email") },
            trailingIcon = {
                if (uiState.canClear) {
                    TextButton(onClick = onClear) {
                        Text(text = "Clear")
                    }
                }
            }
        )

        FcBanner(
            title = "Local truth",
            message = uiState.localTruthMessage,
            tone = uiState.localTruthTone,
            modifier = Modifier.fillMaxWidth()
        )

        if (uiState.isShowingDetail && uiState.detailUiState != null) {
            AttendeeDetailScreen(
                uiState = uiState.detailUiState,
                onBack = onBack,
                onClear = onClear,
                onManualAdmit = onManualAdmit,
                modifier = Modifier.fillMaxWidth()
            )
            return
        }

        if (uiState.results.isEmpty()) {
            FcCard(modifier = Modifier.fillMaxWidth()) {
                Text(
                    text = uiState.emptyStateMessage,
                    style = MaterialTheme.typography.bodyMedium
                )
            }
            return
        }

        LazyColumn(
            modifier = Modifier.fillMaxWidth(),
            verticalArrangement = Arrangement.spacedBy(spacing.small)
        ) {
            items(uiState.results, key = SearchResultRowUiModel::attendeeId) { row ->
                FcCard(
                    modifier =
                        Modifier
                            .fillMaxWidth()
                            .clickable { onSelectAttendee(row.attendeeId) }
                ) {
                    Column(verticalArrangement = Arrangement.spacedBy(spacing.small)) {
                        Text(text = row.displayName, style = MaterialTheme.typography.titleMedium)
                        Text(text = row.supportingText, style = MaterialTheme.typography.bodyMedium)
                        FcStatusChip(text = row.statusText, tone = row.statusTone)
                    }
                }
            }
        }
    }
}
