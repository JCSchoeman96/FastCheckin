/**
 * Reusable action row for scanner-result follow-up actions.
 */
package za.co.voelgoed.fastcheck.core.designsystem.components

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import za.co.voelgoed.fastcheck.core.designsystem.theme.fastCheck

@Composable
fun FcScanResultActionsRow(
    primaryText: String,
    onPrimaryClick: () -> Unit,
    modifier: Modifier = Modifier,
    secondaryText: String? = null,
    onSecondaryClick: (() -> Unit)? = null,
) {
    val spacing = MaterialTheme.fastCheck.spacing

    if (secondaryText != null && onSecondaryClick != null) {
        Row(
            modifier = modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(spacing.small),
        ) {
            FcSecondaryButton(
                text = secondaryText,
                onClick = onSecondaryClick,
                modifier = Modifier.weight(1f),
            )
            FcPrimaryButton(
                text = primaryText,
                onClick = onPrimaryClick,
                modifier = Modifier.weight(1f),
            )
        }
    } else {
        FcPrimaryButton(
            text = primaryText,
            onClick = onPrimaryClick,
            modifier = modifier.fillMaxWidth(),
        )
    }
}
