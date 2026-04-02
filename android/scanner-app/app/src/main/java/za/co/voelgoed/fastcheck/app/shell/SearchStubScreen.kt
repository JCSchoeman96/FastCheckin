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
fun SearchStubScreen(modifier: Modifier = Modifier) {
    val spacing = MaterialTheme.fastCheck.spacing

    Column(
        modifier = modifier,
        verticalArrangement = Arrangement.spacedBy(spacing.medium)
    ) {
        FcBanner(
            title = "Search is not live yet",
            message = "Attendee search and manual check-in move into this destination in Phase 11.",
            tone = StatusTone.Info,
            modifier = Modifier.fillMaxWidth()
        )
        FcCard(modifier = Modifier.fillMaxWidth()) {
            Column(verticalArrangement = Arrangement.spacedBy(spacing.small)) {
                Text(
                    text = "Planned next",
                    style = MaterialTheme.typography.titleMedium
                )
                Text(
                    text = "This shell placeholder does not imply any new backend search API. Phase 11 will use Android-side DAO, model, and projection work on the current attendee cache."
                )
            }
        }
    }
}
