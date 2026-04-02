package za.co.voelgoed.fastcheck.core.designsystem.preview

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.tooling.preview.Preview
import za.co.voelgoed.fastcheck.core.designsystem.components.FcBanner
import za.co.voelgoed.fastcheck.core.designsystem.semantic.StatusTone
import za.co.voelgoed.fastcheck.core.designsystem.theme.FastCheckTheme
import za.co.voelgoed.fastcheck.core.designsystem.theme.fastCheck

@Preview(name = "FcBanner", showBackground = true)
@Composable
internal fun FcBannerPreview() {
    FastCheckTheme {
        val theme = MaterialTheme.fastCheck

        Surface {
            Column(
                modifier =
                    Modifier
                        .fillMaxWidth()
                        .padding(theme.spacing.large),
                verticalArrangement = Arrangement.spacedBy(theme.spacing.small),
            ) {
                FcBanner(
                    title = "Offline",
                    message = "Scans stay queued locally until connectivity returns.",
                    tone = StatusTone.Offline,
                )
                FcBanner(
                    title = "Sync warning",
                    message = "Some queued scans still need to be flushed.",
                    tone = StatusTone.Warning,
                )
                FcBanner(
                    title = "Sync complete",
                    message = "All queued scans have been uploaded.",
                    tone = StatusTone.Success,
                )
            }
        }
    }
}
