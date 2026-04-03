package za.co.voelgoed.fastcheck.feature.attendees

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.weight
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.item
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Button
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

@Composable
fun AttendeeSearchScreen(
    uiState: AttendeeSearchUiState,
    onQueryChanged: (String) -> Unit,
    onAttendeeSelected: (Long) -> Unit,
    onBackToResults: () -> Unit,
    onDismissActionBanner: () -> Unit,
    onQueueManualCheckIn: () -> Unit,
    modifier: Modifier = Modifier
) {
    val spacing = MaterialTheme.fastCheck.spacing

    Column(
        modifier = modifier.fillMaxSize(),
        verticalArrangement = Arrangement.spacedBy(spacing.medium)
    ) {
        FcCard(modifier = Modifier.fillMaxWidth()) {
            Column(verticalArrangement = Arrangement.spacedBy(spacing.small)) {
                Text(text = "Search", style = MaterialTheme.typography.headlineSmall)
                Text(
                    text = "Look up attendees from the local cache and use manual check-in only when scanning is not practical.",
                    style = MaterialTheme.typography.bodyMedium
                )
            }
        }

        uiState.syncBanner?.let { banner ->
            FcBanner(
                title = banner.title,
                message = banner.message,
                tone = banner.tone,
                modifier = Modifier.fillMaxWidth()
            )
        }

        OutlinedTextField(
            value = uiState.query,
            onValueChange = onQueryChanged,
            label = { Text("Search attendees") },
            placeholder = { Text("Ticket code, name, or email") },
            modifier = Modifier.fillMaxWidth(),
            singleLine = true
        )

        if (uiState.isShowingSelection) {
            DetailContent(
                attendee = uiState.selectedAttendee,
                actionBanner = uiState.actionBanner,
                isSubmittingManualCheckIn = uiState.isSubmittingManualCheckIn,
                onBackToResults = onBackToResults,
                onDismissActionBanner = onDismissActionBanner,
                onQueueManualCheckIn = onQueueManualCheckIn,
                modifier = Modifier.weight(1f)
            )
        } else {
            ResultsContent(
                uiState = uiState,
                onAttendeeSelected = onAttendeeSelected
            )
        }
    }
}

@Composable
private fun ResultsContent(
    uiState: AttendeeSearchUiState,
    onAttendeeSelected: (Long) -> Unit
) {
    val spacing = MaterialTheme.fastCheck.spacing

    when (uiState.emptyState) {
        SearchEmptyState.Prompt ->
            FcCard(modifier = Modifier.fillMaxWidth()) {
                Text(
                    text = "Start typing to search the local attendee cache. Blank search does not load the full attendee list.",
                    style = MaterialTheme.typography.bodyMedium
                )
            }

        SearchEmptyState.NoResults ->
            FcCard(modifier = Modifier.fillMaxWidth()) {
                Text(
                    text = "No attendees match this local search.",
                    style = MaterialTheme.typography.bodyMedium
                )
            }

        SearchEmptyState.Hidden -> {
            if (uiState.results.isNotEmpty()) {
                LazyColumn(
                    verticalArrangement = Arrangement.spacedBy(spacing.small),
                    modifier = Modifier.fillMaxWidth()
                ) {
                    items(uiState.results, key = { it.id }) { attendee ->
                        FcCard(
                            modifier =
                                Modifier
                                    .fillMaxWidth()
                                    .clickable { onAttendeeSelected(attendee.id) }
                        ) {
                            ResultCardContent(attendee = attendee)
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun DetailContent(
    attendee: AttendeeDetailUiModel?,
    actionBanner: AttendeeSearchBannerUiModel?,
    isSubmittingManualCheckIn: Boolean,
    onBackToResults: () -> Unit,
    onDismissActionBanner: () -> Unit,
    onQueueManualCheckIn: () -> Unit,
    modifier: Modifier = Modifier
) {
    val spacing = MaterialTheme.fastCheck.spacing

    LazyColumn(
        verticalArrangement = Arrangement.spacedBy(spacing.medium),
        modifier = modifier.fillMaxWidth()
    ) {
        item {
            TextButton(onClick = onBackToResults) {
                Text("Back to results")
            }
        }

        actionBanner?.let { banner ->
            item {
                Column(verticalArrangement = Arrangement.spacedBy(spacing.small)) {
                    FcBanner(
                        title = banner.title,
                        message = banner.message,
                        tone = banner.tone,
                        modifier = Modifier.fillMaxWidth()
                    )
                    TextButton(onClick = onDismissActionBanner) {
                        Text("Dismiss")
                    }
                }
            }
        }

        if (attendee == null) {
            item {
                FcCard(modifier = Modifier.fillMaxWidth()) {
                    Text(
                        text = "Loading attendee detail from the local cache.",
                        style = MaterialTheme.typography.bodyMedium
                    )
                }
            }
        } else {
            item {
                FcCard(modifier = Modifier.fillMaxWidth()) {
                    Column(verticalArrangement = Arrangement.spacedBy(spacing.small)) {
                        Text(text = attendee.displayName, style = MaterialTheme.typography.headlineSmall)
                        Text(text = attendee.ticketCode, style = MaterialTheme.typography.bodyMedium)
                        attendee.email?.let {
                            Text(text = it, style = MaterialTheme.typography.bodyMedium)
                        }
                        attendee.ticketType?.let {
                            Text(text = "Ticket type: $it", style = MaterialTheme.typography.bodyMedium)
                        }
                        FcStatusChip(text = attendee.paymentLabel, tone = attendee.paymentTone)
                        FcStatusChip(text = attendee.attendanceLabel, tone = attendee.attendanceTone)
                        Text(text = attendee.allowedCheckinsLabel, style = MaterialTheme.typography.bodyMedium)
                        Text(text = attendee.remainingCheckinsLabel, style = MaterialTheme.typography.bodyMedium)
                        attendee.checkedInAt?.let {
                            Text(text = "Checked in at: $it", style = MaterialTheme.typography.bodySmall)
                        }
                        attendee.checkedOutAt?.let {
                            Text(text = "Checked out at: $it", style = MaterialTheme.typography.bodySmall)
                        }
                        attendee.updatedAt?.let {
                            Text(text = "Local snapshot updated: $it", style = MaterialTheme.typography.bodySmall)
                        }
                    }
                }
            }

            item {
                FcCard(modifier = Modifier.fillMaxWidth()) {
                    Column(verticalArrangement = Arrangement.spacedBy(spacing.small)) {
                        Text(
                            text = "Manual check-in",
                            style = MaterialTheme.typography.titleMedium
                        )
                        Text(
                            text = "This action queues a local IN scan and waits for upload. It does not imply immediate server confirmation.",
                            style = MaterialTheme.typography.bodyMedium
                        )
                        Button(
                            onClick = onQueueManualCheckIn,
                            enabled = !isSubmittingManualCheckIn
                        ) {
                            Text(
                                if (isSubmittingManualCheckIn) {
                                    "Queueing..."
                                } else {
                                    "Queue manual check-in"
                                }
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun ResultCardContent(attendee: AttendeeSearchResultUiModel) {
    val spacing = MaterialTheme.fastCheck.spacing

    Column(verticalArrangement = Arrangement.spacedBy(spacing.small)) {
        Text(
            text = attendee.displayName,
            style = MaterialTheme.typography.titleMedium
        )
        Text(
            text = attendee.ticketCode,
            style = MaterialTheme.typography.bodyMedium
        )
        Text(
            text = attendee.supportingText,
            style = MaterialTheme.typography.bodySmall
        )
        FcStatusChip(
            text = attendee.statusLabel,
            tone = attendee.statusTone
        )
    }
}
