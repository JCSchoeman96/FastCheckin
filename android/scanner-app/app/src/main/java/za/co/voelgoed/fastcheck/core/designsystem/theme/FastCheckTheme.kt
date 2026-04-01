/**
 * FastCheck Compose theme wrapper.
 *
 * Provides the top-level MaterialTheme with FastCheck color, typography,
 * and shape overrides. Feature screens and design-system previews should
 * wrap their content in [FastCheckTheme] to pick up the correct tokens.
 */
package za.co.voelgoed.fastcheck.core.designsystem.theme

import androidx.compose.material3.ColorScheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Shapes
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.remember
import za.co.voelgoed.fastcheck.core.designsystem.semantic.ColorRoles
import za.co.voelgoed.fastcheck.core.designsystem.semantic.lightColorRoles
import za.co.voelgoed.fastcheck.core.designsystem.tokens.FastCheckTypography
import za.co.voelgoed.fastcheck.core.designsystem.tokens.ShapeTokens

private val FastCheckShapes = Shapes(
    extraSmall = ShapeTokens.Small,
    small = ShapeTokens.Small,
    medium = ShapeTokens.Medium,
    large = ShapeTokens.Large,
    extraLarge = ShapeTokens.XLarge,
)

@Composable
fun FastCheckTheme(content: @Composable () -> Unit) {
    val colorRoles = remember { lightColorRoles() }
    val materialColors = remember(colorRoles) { colorRoles.toMaterialColorScheme() }

    CompositionLocalProvider(
        LocalColorRoles provides colorRoles,
    ) {
        MaterialTheme(
            colorScheme = materialColors,
            typography = FastCheckTypography,
            shapes = FastCheckShapes,
            content = content,
        )
    }
}

private fun ColorRoles.toMaterialColorScheme(): ColorScheme =
    lightColorScheme(
        primary = interactivePrimary,
        onPrimary = textInverse,
        secondary = interactiveSecondary,
        onSecondary = textInverse,
        background = surfaceBase,
        onBackground = textPrimary,
        surface = surfaceRaised,
        onSurface = textPrimary,
        surfaceVariant = surfaceMuted,
        onSurfaceVariant = textSecondary,
        error = destructive,
        onError = textInverse,
        outline = borderStrong,
        outlineVariant = borderSubtle,
    )
