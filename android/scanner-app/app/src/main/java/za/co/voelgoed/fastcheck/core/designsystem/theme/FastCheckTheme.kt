/**
 * FastCheck Compose theme wrapper.
 *
 * Provides the top-level MaterialTheme with FastCheck color, typography,
 * shape, spacing, elevation, and semantic status-role access. Feature
 * screens and design-system previews should wrap their content in
 * [FastCheckTheme] to pick up the correct tokens.
 */
package za.co.voelgoed.fastcheck.core.designsystem.theme

import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.remember
import androidx.compose.runtime.staticCompositionLocalOf

internal val LocalFastCheckThemeValues = staticCompositionLocalOf {
    buildFastCheckThemeValues()
}

@Composable
fun FastCheckTheme(content: @Composable () -> Unit) {
    val values = remember { buildFastCheckThemeValues() }

    CompositionLocalProvider(LocalFastCheckThemeValues provides values) {
        MaterialTheme(
            colorScheme = values.colorScheme,
            typography = values.typography,
            shapes = values.shapes,
            content = content
        )
    }
}
