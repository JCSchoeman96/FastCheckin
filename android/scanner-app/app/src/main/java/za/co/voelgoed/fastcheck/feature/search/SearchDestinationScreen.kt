package za.co.voelgoed.fastcheck.feature.search

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
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
    val theme = MaterialTheme.fastCheck
    val scheme = theme.colorScheme

    Column(
        modifier = modifier,
        verticalArrangement = Arrangement.spacedBy(spacing.medium)
    ) {
        OutlinedTextField(
            value = uiState.query,
            onValueChange = onQueryChanged,
            modifier =
                Modifier
                    .fillMaxWidth()
                    .semantics { contentDescription = "Search attendees" },
            singleLine = true,
            label = null,
            placeholder = {
                Text(
                    text = "Ticket code, name, or email",
                    style = theme.typography.bodyLarge,
                    color = scheme.onSurfaceVariant
                )
            },
            leadingIcon = {
                Icon(
                    imageVector = Icons.Outlined.Search,
                    contentDescription = null,
                    tint = scheme.onSurfaceVariant
                )
            },
            trailingIcon = {
                if (uiState.canClear) {
                    TextButton(onClick = onClear) {
                        Text(text = "Clear")
                    }
                }
            },
            shape = theme.shapes.medium,
            colors =
                OutlinedTextFieldDefaults.colors(
                    focusedTextColor = scheme.onSurface,
                    unfocusedTextColor = scheme.onSurface,
                    focusedBorderColor = scheme.outline,
                    unfocusedBorderColor = scheme.outlineVariant,
                    cursorColor = scheme.tertiary,
                    focusedPlaceholderColor = scheme.onSurfaceVariant,
                    unfocusedPlaceholderColor = scheme.onSurfaceVariant,
                )
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

        when {
            uiState.results.isEmpty() && uiState.query.isBlank() -> {
                FcCard(modifier = Modifier.fillMaxWidth()) {
                    Column(
                        modifier = Modifier.fillMaxWidth(),
                        verticalArrangement = Arrangement.spacedBy(spacing.small)
                    ) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(spacing.small)
                        ) {
                            Icon(
                                imageVector = Icons.Outlined.Search,
                                contentDescription = null,
                                tint = scheme.onSurfaceVariant
                            )
                            Text(
                                text = "Search attendees",
                                style = theme.typography.titleMedium,
                                color = scheme.onSurface,
                                fontWeight = FontWeight.SemiBold
                            )
                        }
                        Text(
                            text = uiState.emptyStateMessage,
                            style = theme.typography.bodyMedium,
                            color = scheme.onSurfaceVariant
                        )
                    }
                }
            }

            uiState.results.isEmpty() && uiState.query.isNotBlank() -> {
                FcCard(modifier = Modifier.fillMaxWidth()) {
                    Column(
                        modifier = Modifier.fillMaxWidth(),
                        verticalArrangement = Arrangement.spacedBy(spacing.xSmall)
                    ) {
                        Text(
                            text = "No attendees found",
                            style = theme.typography.titleMedium,
                            color = scheme.onSurface,
                            fontWeight = FontWeight.SemiBold
                        )
                        Text(
                            text = uiState.emptyStateMessage,
                            style = theme.typography.bodyMedium,
                            color = scheme.onSurfaceVariant
                        )
                        Text(
                            text = "Try ticket code, full name, or email.",
                            style = theme.typography.bodySmall,
                            color = scheme.onSurfaceVariant
                        )
                    }
                }
            }

            else -> {
                LazyColumn(
                    modifier = Modifier.fillMaxWidth(),
                    verticalArrangement = Arrangement.spacedBy(spacing.xSmall)
                ) {
                    items(uiState.results, key = SearchResultRowUiModel::attendeeId) { row ->
                        FcCard(
                            modifier =
                                Modifier
                                    .fillMaxWidth()
                                    .clickable { onSelectAttendee(row.attendeeId) }
                        ) {
                            Column(
                                modifier = Modifier.fillMaxWidth(),
                                verticalArrangement = Arrangement.spacedBy(spacing.xxSmall)
                            ) {
                                Text(
                                    text = row.displayName,
                                    style = theme.typography.titleMedium,
                                    color = scheme.onSurface,
                                    fontWeight = FontWeight.SemiBold,
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis
                                )
                                Text(
                                    text = row.supportingText,
                                    style = theme.typography.bodySmall,
                                    color = scheme.onSurfaceVariant,
                                    maxLines = 2,
                                    overflow = TextOverflow.Ellipsis
                                )
                                FcStatusChip(
                                    text = row.statusText,
                                    tone = row.statusTone,
                                    modifier = Modifier.padding(top = spacing.xxSmall)
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}
