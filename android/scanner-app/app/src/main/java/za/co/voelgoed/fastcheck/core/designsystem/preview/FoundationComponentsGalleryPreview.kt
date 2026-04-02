package za.co.voelgoed.fastcheck.core.designsystem.preview

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.tooling.preview.Preview
import za.co.voelgoed.fastcheck.core.designsystem.components.FcBanner
import za.co.voelgoed.fastcheck.core.designsystem.components.FcCard
import za.co.voelgoed.fastcheck.core.designsystem.components.FcStatusChip
import za.co.voelgoed.fastcheck.core.designsystem.semantic.StatusTone
import za.co.voelgoed.fastcheck.core.designsystem.theme.FastCheckTheme
import za.co.voelgoed.fastcheck.core.designsystem.theme.fastCheck

@Preview(name = "FoundationGallery", showBackground = true)
@Composable
internal fun FoundationComponentsGalleryPreview() {
    FastCheckTheme {
        val theme = MaterialTheme.fastCheck

        Surface {
            Column(
                modifier =
                    Modifier
                        .fillMaxWidth()
                        .padding(theme.spacing.large),
                verticalArrangement = Arrangement.spacedBy(theme.spacing.large),
            ) {
                GallerySection(title = "Tone vocabulary") {
                    ToneLegend(theme = theme)
                }

                GallerySection(title = "Status chips") {
                    Row(horizontalArrangement = Arrangement.spacedBy(theme.spacing.small)) {
                        FcStatusChip(text = "Synced", tone = StatusTone.Success)
                        FcStatusChip(text = "Offline", tone = StatusTone.Offline)
                        FcStatusChip(text = "Duplicate", tone = StatusTone.Duplicate)
                    }
                    Row(horizontalArrangement = Arrangement.spacedBy(theme.spacing.small)) {
                        FcStatusChip(text = "Warning", tone = StatusTone.Warning)
                        FcStatusChip(text = "Info", tone = StatusTone.Info)
                        FcStatusChip(text = "Muted", tone = StatusTone.Muted)
                    }
                }

                GallerySection(title = "Banners") {
                    Column(verticalArrangement = Arrangement.spacedBy(theme.spacing.small)) {
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
                        FcBanner(
                            title = "Sync info",
                            message = "The scanner is waiting for the next sync window.",
                            tone = StatusTone.Info,
                        )
                    }
                }

                GallerySection(title = "Card") {
                    FcCard(modifier = Modifier.fillMaxWidth()) {
                        Column(verticalArrangement = Arrangement.spacedBy(theme.spacing.xxSmall)) {
                            Text(
                                text = "Queued scans",
                                style = theme.typography.titleMedium,
                            )
                            Text(
                                text = "3 scans are waiting for connectivity.",
                                style = theme.typography.bodyMedium,
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun GallerySection(
    title: String,
    content: @Composable () -> Unit,
) {
    val theme = MaterialTheme.fastCheck

    Column(verticalArrangement = Arrangement.spacedBy(theme.spacing.small)) {
        Text(
            text = title,
            style = theme.typography.titleLarge,
        )
        content()
    }
}

@Composable
private fun ToneLegend(theme: za.co.voelgoed.fastcheck.core.designsystem.theme.FastCheckThemeValues) {
    Column(verticalArrangement = Arrangement.spacedBy(theme.spacing.small)) {
        Row(horizontalArrangement = Arrangement.spacedBy(theme.spacing.small)) {
            FcStatusChip(text = "Neutral", tone = StatusTone.Neutral)
            FcStatusChip(text = "Brand", tone = StatusTone.Brand)
            FcStatusChip(text = "Success", tone = StatusTone.Success)
        }
        Row(horizontalArrangement = Arrangement.spacedBy(theme.spacing.small)) {
            FcStatusChip(text = "Warning", tone = StatusTone.Warning)
            FcStatusChip(text = "Info", tone = StatusTone.Info)
            FcStatusChip(text = "Destructive", tone = StatusTone.Destructive)
        }
        Row(horizontalArrangement = Arrangement.spacedBy(theme.spacing.small)) {
            FcStatusChip(text = "Duplicate", tone = StatusTone.Duplicate)
            FcStatusChip(text = "Offline", tone = StatusTone.Offline)
            FcStatusChip(text = "Muted", tone = StatusTone.Muted)
        }
    }
}
