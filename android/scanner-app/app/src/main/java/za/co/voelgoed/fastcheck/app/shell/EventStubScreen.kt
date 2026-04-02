package za.co.voelgoed.fastcheck.app.shell

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
fun EventStubScreen(modifier: Modifier = Modifier) {
    val spacing = MaterialTheme.fastCheck.spacing

    Column(
        modifier = modifier,
        verticalArrangement = Arrangement.spacedBy(spacing.medium)
    ) {
        FcBanner(
            title = "Event is not live yet",
            message = "Operational sync health, queue state, and support-oriented event status move here in Phase 12.",
            tone = StatusTone.Info,
            modifier = Modifier.fillMaxWidth()
        )
        FcCard(modifier = Modifier.fillMaxWidth()) {
            Column(verticalArrangement = Arrangement.spacedBy(spacing.small)) {
                Text(
                    text = "What this does not do",
                    style = MaterialTheme.typography.titleMedium
                )
                Text(
                    text = "This stub does not expose API target details as product UI and does not turn diagnostics into a primary tab."
                )
            }
        }
    }
}
