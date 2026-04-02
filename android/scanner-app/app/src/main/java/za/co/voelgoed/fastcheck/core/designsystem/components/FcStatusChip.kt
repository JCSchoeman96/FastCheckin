package za.co.voelgoed.fastcheck.core.designsystem.components

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.style.TextOverflow
import za.co.voelgoed.fastcheck.core.designsystem.tokens.IconTokens
import za.co.voelgoed.fastcheck.core.designsystem.semantic.StatusTone
import za.co.voelgoed.fastcheck.core.designsystem.theme.fastCheck

@Composable
fun FcStatusChip(
    text: String,
    tone: StatusTone,
    modifier: Modifier = Modifier,
    icon: ImageVector? = null,
) {
    val theme = MaterialTheme.fastCheck
    val accent = theme.statusRoles.resolve(tone)
    val colors = resolveToneSurfaceColors(accent, containerAlpha = 0.12f)

    Surface(
        modifier = modifier,
        shape = theme.shapes.extraLarge,
        color = colors.containerColor,
        contentColor = colors.contentColor,
    ) {
        Row(
            modifier =
                Modifier.padding(
                    horizontal = theme.spacing.small,
                    vertical = theme.spacing.xxSmall,
                ),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(theme.spacing.xxSmall),
        ) {
            if (icon != null) {
                Icon(
                    imageVector = icon,
                    contentDescription = null,
                    modifier = Modifier.size(IconTokens.Small),
                )
            }
            Text(
                text = text,
                style = theme.typography.labelMedium,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}
