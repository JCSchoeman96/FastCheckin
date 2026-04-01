/**
 * Local CompositionLocal extensions exposed through [FastCheckTheme].
 *
 * Provides app-specific token accessors (spacing, elevation, status tones)
 * that sit alongside MaterialTheme's built-in color/typography/shapes.
 */
package za.co.voelgoed.fastcheck.core.designsystem.theme

import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.ReadOnlyComposable
import androidx.compose.runtime.staticCompositionLocalOf
import za.co.voelgoed.fastcheck.core.designsystem.semantic.ColorRoles
import za.co.voelgoed.fastcheck.core.designsystem.semantic.StatusRoleColors
import za.co.voelgoed.fastcheck.core.designsystem.semantic.StatusTone
import za.co.voelgoed.fastcheck.core.designsystem.semantic.lightColorRoles

internal val LocalColorRoles = staticCompositionLocalOf { lightColorRoles() }

val MaterialTheme.colorRoles: ColorRoles
    @Composable
    @ReadOnlyComposable
    get() = LocalColorRoles.current

@Composable
@ReadOnlyComposable
fun statusRoleColors(tone: StatusTone): StatusRoleColors =
    LocalColorRoles.current.status.forTone(tone)
