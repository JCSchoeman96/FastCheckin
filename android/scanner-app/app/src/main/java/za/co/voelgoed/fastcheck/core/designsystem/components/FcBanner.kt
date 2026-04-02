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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import za.co.voelgoed.fastcheck.core.designsystem.semantic.StatusTone
import za.co.voelgoed.fastcheck.core.designsystem.tokens.IconTokens
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
    val colors = resolveBannerColors(accent)

    Surface(
        modifier = modifier,
        shape = theme.shapes.large,
        color = colors.containerColor,
        contentColor = colors.contentColor,
        border = BorderStroke(1.dp, colors.borderColor),
        shadowElevation = theme.elevation.low,
    ) {
        Row(
            modifier =
                Modifier
                    .fillMaxWidth()
                    .padding(
                        horizontal = theme.spacing.medium,
                        vertical = theme.spacing.small,
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

private data class FcBannerColors(
    val containerColor: Color,
    val contentColor: Color,
    val borderColor: Color,
)

private fun resolveBannerColors(accent: Color): FcBannerColors =
    FcBannerColors(
        containerColor = accent.copy(alpha = 0.08f),
        contentColor = accent,
        borderColor = accent.copy(alpha = 0.24f),
    )
