package za.co.voelgoed.fastcheck.core.designsystem.preview

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.tooling.preview.Preview
import za.co.voelgoed.fastcheck.core.designsystem.components.FcCard
import za.co.voelgoed.fastcheck.core.designsystem.theme.FastCheckTheme
import za.co.voelgoed.fastcheck.core.designsystem.theme.fastCheck

@Preview(name = "FcCard", showBackground = true)
@Composable
internal fun FcCardPreview() {
    FastCheckTheme {
        val theme = MaterialTheme.fastCheck

        Surface {
            Column(
                modifier =
                    Modifier
                        .fillMaxWidth()
                        .padding(theme.spacing.large),
            ) {
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
