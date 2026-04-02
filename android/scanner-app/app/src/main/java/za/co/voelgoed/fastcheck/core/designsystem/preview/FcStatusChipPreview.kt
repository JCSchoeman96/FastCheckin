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
import za.co.voelgoed.fastcheck.core.designsystem.components.FcStatusChip
import za.co.voelgoed.fastcheck.core.designsystem.semantic.StatusTone
import za.co.voelgoed.fastcheck.core.designsystem.theme.FastCheckTheme
import za.co.voelgoed.fastcheck.core.designsystem.theme.fastCheck

@Preview(name = "FcStatusChip", showBackground = true)
@Composable
internal fun FcStatusChipPreview() {
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
                FcStatusChip(text = "Synced", tone = StatusTone.Success)
                FcStatusChip(text = "Offline", tone = StatusTone.Offline)
                FcStatusChip(text = "Duplicate scan", tone = StatusTone.Duplicate)
            }
        }
    }
}
