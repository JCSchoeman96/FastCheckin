/**
 * Secondary details card for scanner-result metadata rows.
 */
package za.co.voelgoed.fastcheck.core.designsystem.components

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.width
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import za.co.voelgoed.fastcheck.core.designsystem.theme.fastCheck

@Immutable
data class FcScanResultDetailItem(
    val label: String,
    val value: String,
)

@Composable
fun FcScanResultDetailsCard(
    items: List<FcScanResultDetailItem>,
    modifier: Modifier = Modifier,
    title: String = "Original entry metadata",
) {
    if (items.isEmpty()) return

    val theme = MaterialTheme.fastCheck

    FcCard(modifier = modifier) {
        Column(
            verticalArrangement = Arrangement.spacedBy(theme.spacing.medium),
        ) {
            Text(
                text = title.uppercase(),
                style = theme.typography.labelMedium,
                fontWeight = FontWeight.Bold,
                color = theme.colorScheme.onSurfaceVariant,
            )

            items.forEachIndexed { index, item ->
                Column(
                    verticalArrangement = Arrangement.spacedBy(theme.spacing.xSmall),
                ) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.spacedBy(theme.spacing.small),
                        verticalAlignment = Alignment.Top,
                    ) {
                        BoxWithConstraints(modifier = Modifier.fillMaxWidth()) {
                            val labelWidth = maxWidth * 0.42f
                            val valueWidth = maxWidth - labelWidth - theme.spacing.small
                            Text(
                                text = item.label.uppercase(),
                                style = theme.typography.labelMedium,
                                fontWeight = FontWeight.Bold,
                                color = theme.colorScheme.onSurfaceVariant,
                                modifier = Modifier.width(labelWidth),
                            )

                            Text(
                                text = item.value,
                                style = theme.typography.bodyLarge,
                                fontWeight = FontWeight.Bold,
                                color = theme.colorScheme.onSurface,
                                textAlign = TextAlign.End,
                                modifier = Modifier.width(valueWidth),
                            )
                        }
                    }

                    if (index < items.lastIndex) {
                        Spacer(
                            modifier =
                                Modifier
                                    .fillMaxWidth()
                                    .height(1.dp)
                                    .background(theme.colorScheme.outlineVariant.copy(alpha = 0.50f)),
                        )
                    }
                }
            }
        }
    }
}
