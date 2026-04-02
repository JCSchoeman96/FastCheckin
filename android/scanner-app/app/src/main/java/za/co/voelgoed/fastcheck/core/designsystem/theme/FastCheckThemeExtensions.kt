/**
 * Local CompositionLocal extensions exposed through [FastCheckTheme].
 *
 * Provides app-specific token accessors through one aggregate surface that
 * sits alongside MaterialTheme's built-in color/typography/shapes.
 */
package za.co.voelgoed.fastcheck.core.designsystem.theme

import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable

val MaterialTheme.fastCheck: FastCheckThemeValues
    @Composable
    get() = LocalFastCheckThemeValues.current
