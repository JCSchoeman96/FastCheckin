package za.co.voelgoed.fastcheck.feature.search.detail

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import za.co.voelgoed.fastcheck.core.designsystem.components.FcBanner
import za.co.voelgoed.fastcheck.core.designsystem.components.FcCard
import za.co.voelgoed.fastcheck.core.designsystem.components.FcPrimaryButton
import za.co.voelgoed.fastcheck.core.designsystem.components.FcSecondaryButton
import za.co.voelgoed.fastcheck.core.designsystem.components.FcStatusChip
import za.co.voelgoed.fastcheck.core.designsystem.theme.fastCheck
import za.co.voelgoed.fastcheck.feature.search.detail.model.AttendeeDetailUiState

@Composable
fun AttendeeDetailScreen(
    uiState: AttendeeDetailUiState,
    onBack: () -> Unit,
    onManualAdmit: () -> Unit,
    modifier: Modifier = Modifier
) {
    val spacing = MaterialTheme.fastCheck.spacing

    Column(
        modifier = modifier,
        verticalArrangement = Arrangement.spacedBy(spacing.medium)
    ) {
        FcCard(modifier = Modifier.fillMaxWidth()) {
            Column(verticalArrangement = Arrangement.spacedBy(spacing.small)) {
                Text(text = uiState.displayName, style = MaterialTheme.typography.headlineSmall)
                Text(text = uiState.ticketCode, style = MaterialTheme.typography.bodyMedium)
                FcStatusChip(text = uiState.attendanceStatusLabel, tone = uiState.attendanceStatusTone)
                Text(text = uiState.allowedCheckinsLabel, style = MaterialTheme.typography.bodyMedium)
                Text(text = uiState.remainingCheckinsLabel, style = MaterialTheme.typography.bodyMedium)
                uiState.email?.let { Text(text = it, style = MaterialTheme.typography.bodyMedium) }
                uiState.ticketType?.let { Text(text = "Ticket type: $it", style = MaterialTheme.typography.bodyMedium) }
                uiState.paymentStatus?.let { Text(text = "Payment: $it", style = MaterialTheme.typography.bodyMedium) }
                uiState.checkedInAt?.let { Text(text = "Checked in: $it", style = MaterialTheme.typography.bodySmall) }
                uiState.checkedOutAt?.let { Text(text = "Checked out: $it", style = MaterialTheme.typography.bodySmall) }
                Text(text = uiState.localTruthNote, style = MaterialTheme.typography.bodySmall)
            }
        }

        uiState.conflictTitle?.let { title ->
            FcBanner(
                title = title,
                message = uiState.conflictMessage ?: "An unresolved local conflict is blocking fresh admission on this device.",
                tone = uiState.attendanceStatusTone,
                modifier = Modifier.fillMaxWidth()
            )
        }

        uiState.manualActionUiState.feedbackMessage?.let { message ->
            FcBanner(
                title = uiState.manualActionUiState.feedbackTitle,
                message = message,
                tone = uiState.manualActionUiState.feedbackTone ?: uiState.attendanceStatusTone,
                modifier = Modifier.fillMaxWidth()
            )
        }

        FcCard(modifier = Modifier.fillMaxWidth()) {
            Column(verticalArrangement = Arrangement.spacedBy(spacing.small)) {
                Text(text = "Actions", style = MaterialTheme.typography.titleMedium)
                FcPrimaryButton(
                    text = if (uiState.manualActionUiState.isRunning) "Checking in..." else "Check in attendee",
                    onClick = onManualAdmit,
                    modifier = Modifier.fillMaxWidth(),
                    enabled = !uiState.manualActionUiState.isRunning
                )
                FcSecondaryButton(
                    text = "Back to results",
                    onClick = onBack,
                    modifier = Modifier.fillMaxWidth(),
                    enabled = !uiState.manualActionUiState.isRunning
                )
            }
        }
    }
}
