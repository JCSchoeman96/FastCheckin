package za.co.voelgoed.fastcheck.core.designsystem.components

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import za.co.voelgoed.fastcheck.core.designsystem.tokens.StrokeTokens
import za.co.voelgoed.fastcheck.core.designsystem.theme.fastCheck

@Composable
fun FcCard(
    modifier: Modifier = Modifier,
    content: @Composable () -> Unit,
) {
    val theme = MaterialTheme.fastCheck

    Surface(
        modifier = modifier,
        shape = theme.shapes.large,
        color = theme.colorScheme.surface,
        contentColor = theme.colorScheme.onSurface,
        shadowElevation = theme.elevation.low,
        border = BorderStroke(StrokeTokens.Hairline, theme.colorScheme.outlineVariant.copy(alpha = 0.5f)),
    ) {
        Box(
            modifier = Modifier.padding(theme.spacing.medium),
        ) {
            content()
        }
    }
}
