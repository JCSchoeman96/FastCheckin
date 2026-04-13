/**
 * Strong scanner-result hero surface for high-visibility capture outcomes.
 */
package za.co.voelgoed.fastcheck.core.designsystem.components

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.HelpOutline
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.CloudOff
import androidx.compose.material.icons.filled.Error
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import za.co.voelgoed.fastcheck.core.designsystem.semantic.StatusTone
import za.co.voelgoed.fastcheck.core.designsystem.theme.fastCheck
import za.co.voelgoed.fastcheck.core.designsystem.tokens.StrokeTokens

@Composable
fun FcScanResultHero(
    title: String,
    tone: StatusTone,
    modifier: Modifier = Modifier,
    message: String? = null,
    icon: ImageVector = scanResultIconFor(tone),
) {
    val theme = MaterialTheme.fastCheck
    val accent = theme.statusRoles.resolve(tone)
    val contentColor =
        scanResultContentColor(
            background = accent,
            lightFallback = theme.colorScheme.onPrimary,
            darkFallback = theme.colorScheme.onSurface,
        )

    val titleTextStyle =
        if (message.isNullOrBlank()) {
            theme.typography.displayMedium
        } else {
            theme.typography.displaySmall
        }

    Surface(
        modifier = modifier,
        shape = theme.shapes.large,
        color = accent,
        contentColor = contentColor,
        border = BorderStroke(StrokeTokens.Hairline, accent.copy(alpha = 0.14f)),
        shadowElevation = theme.elevation.medium,
    ) {
        Row(
            modifier =
                Modifier
                    .fillMaxWidth()
                    .defaultMinSize(minHeight = 96.dp)
                    .padding(
                        horizontal = theme.spacing.large,
                        vertical = theme.spacing.large,
                    ),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(theme.spacing.medium),
        ) {
            Icon(
                imageVector = icon,
                contentDescription = null,
                modifier = Modifier.size(44.dp),
                tint = contentColor,
            )

            Column(
                verticalArrangement = Arrangement.spacedBy(theme.spacing.xxSmall),
            ) {
                Text(
                    text = title.uppercase(),
                    style = titleTextStyle,
                    fontWeight = FontWeight.ExtraBold,
                    color = contentColor,
                )

                if (!message.isNullOrBlank()) {
                    Text(
                        text = message,
                        style = theme.typography.bodyLarge,
                        fontWeight = FontWeight.Medium,
                        color = contentColor.copy(alpha = 0.96f),
                    )
                }
            }
        }
    }
}

private fun scanResultIconFor(tone: StatusTone): ImageVector =
    when (tone) {
        StatusTone.Success -> Icons.Filled.CheckCircle
        StatusTone.Warning -> Icons.Filled.Warning
        StatusTone.Destructive -> Icons.Filled.Error
        StatusTone.Duplicate -> Icons.Filled.Info
        StatusTone.Offline -> Icons.Filled.CloudOff
        StatusTone.Info -> Icons.Filled.Info
        StatusTone.Brand -> Icons.Filled.CheckCircle
        StatusTone.Neutral -> Icons.Filled.Info
        StatusTone.Muted -> Icons.AutoMirrored.Filled.HelpOutline
    }

private fun scanResultContentColor(
    background: Color,
    lightFallback: Color,
    darkFallback: Color,
): Color = if (background.luminance() < 0.45f) lightFallback else darkFallback
