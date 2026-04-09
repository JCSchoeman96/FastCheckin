package za.co.voelgoed.fastcheck.core.designsystem.components

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonColors
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import za.co.voelgoed.fastcheck.core.designsystem.tokens.StrokeTokens
import za.co.voelgoed.fastcheck.core.designsystem.theme.fastCheck

@Composable
fun FcPrimaryButton(
    text: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
) {
    val theme = MaterialTheme.fastCheck

    FcActionButton(
        text = text,
        onClick = onClick,
        modifier = modifier,
        enabled = enabled,
        filled = true,
        colors =
            ButtonDefaults.buttonColors(
                containerColor = theme.colorScheme.primary,
                contentColor = theme.colorScheme.onPrimary,
                disabledContainerColor = theme.colorScheme.onSurface.copy(alpha = 0.12f),
                disabledContentColor = theme.colorScheme.onSurface.copy(alpha = 0.38f),
            ),
    )
}

@Composable
fun FcSecondaryButton(
    text: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
) {
    val theme = MaterialTheme.fastCheck

    FcActionButton(
        text = text,
        onClick = onClick,
        modifier = modifier,
        enabled = enabled,
        filled = false,
        colors =
            ButtonDefaults.outlinedButtonColors(
                containerColor = theme.colorScheme.surface,
                contentColor = theme.colorScheme.onSurface,
                disabledContainerColor = theme.colorScheme.surface,
                disabledContentColor = theme.colorScheme.onSurface.copy(alpha = 0.38f),
            ),
        border = BorderStroke(StrokeTokens.Hairline, theme.colorScheme.outline),
    )
}

@Composable
fun FcDangerButton(
    text: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
) {
    val theme = MaterialTheme.fastCheck

    FcActionButton(
        text = text,
        onClick = onClick,
        modifier = modifier,
        enabled = enabled,
        filled = false,
        colors =
            ButtonDefaults.outlinedButtonColors(
                containerColor = theme.colorScheme.surface,
                contentColor = theme.colorScheme.error,
                disabledContainerColor = theme.colorScheme.surface,
                disabledContentColor = theme.colorScheme.onSurface.copy(alpha = 0.38f),
            ),
        border = BorderStroke(StrokeTokens.Hairline, theme.colorScheme.error),
    )
}

@Composable
private fun FcActionButton(
    text: String,
    onClick: () -> Unit,
    modifier: Modifier,
    enabled: Boolean,
    filled: Boolean,
    colors: ButtonColors,
    border: BorderStroke? = null,
) {
    val theme = MaterialTheme.fastCheck

    if (filled) {
        Button(
            onClick = onClick,
            modifier = modifier,
            enabled = enabled,
            shape = theme.shapes.large,
            contentPadding =
                PaddingValues(
                    horizontal = theme.spacing.medium,
                    vertical = theme.spacing.small,
                ),
            colors = colors,
        ) {
            Text(
                text = text,
                style = theme.typography.labelLarge,
            )
        }
    } else {
        OutlinedButton(
            onClick = onClick,
            modifier = modifier,
            enabled = enabled,
            shape = theme.shapes.large,
            contentPadding =
                PaddingValues(
                    horizontal = theme.spacing.medium,
                    vertical = theme.spacing.small,
                ),
            colors = colors,
            border = border,
        ) {
            Text(
                text = text,
                style = theme.typography.labelLarge,
            )
        }
    }
}
