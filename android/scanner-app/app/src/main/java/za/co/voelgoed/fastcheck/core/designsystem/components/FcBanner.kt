package za.co.voelgoed.fastcheck.core.designsystem.components

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
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
import za.co.voelgoed.fastcheck.core.designsystem.semantic.StatusTone
import za.co.voelgoed.fastcheck.core.designsystem.tokens.IconTokens
import za.co.voelgoed.fastcheck.core.designsystem.tokens.StrokeTokens
import za.co.voelgoed.fastcheck.core.designsystem.theme.fastCheck

@Composable
fun FcBanner(
    message: String,
    tone: StatusTone,
    modifier: Modifier = Modifier,
    title: String? = null,
    icon: ImageVector? = null,
) {
    val theme = MaterialTheme.fastCheck
    val accent = theme.statusRoles.resolve(tone)
    // Slightly stronger fill, softer border, no drop shadow so the banner reads as one flat surface.
    val colors = resolveToneSurfaceColors(accent, containerAlpha = 0.12f, borderAlpha = 0.18f)

    Surface(
        modifier = modifier,
        shape = theme.shapes.large,
        color = colors.containerColor,
        contentColor = colors.contentColor,
        border = BorderStroke(StrokeTokens.Hairline, colors.borderColor),
        shadowElevation = theme.elevation.none,
    ) {
        Row(
            modifier =
                Modifier
                    .fillMaxWidth()
                    .padding(
                        horizontal = theme.spacing.medium,
                        vertical = theme.spacing.medium,
                    ),
            horizontalArrangement = Arrangement.spacedBy(theme.spacing.small),
            verticalAlignment = Alignment.Top,
        ) {
            if (icon != null) {
                Icon(
                    imageVector = icon,
                    contentDescription = null,
                    modifier = Modifier.size(IconTokens.Medium),
                )
            }

            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(theme.spacing.xxSmall),
            ) {
                if (title != null) {
                    Text(
                        text = title,
                        style = theme.typography.titleMedium,
                        color = colors.contentColor,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
                Text(
                    text = message,
                    style = theme.typography.bodyMedium,
                    color = colors.contentColor,
                )
            }
        }
    }
}
