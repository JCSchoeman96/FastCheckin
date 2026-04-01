/**
 * Elevation tokens for FastCheck.
 *
 * A small, subtle elevation scale. Scanner UI is primarily flat; elevation
 * is reserved for cards, sheets, and transient overlays.
 */
package za.co.voelgoed.fastcheck.core.designsystem.tokens

import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

object ElevationTokens {
    val None: Dp = 0.dp
    val Low: Dp = 1.dp
    val Medium: Dp = 3.dp
    val High: Dp = 6.dp
    val Overlay: Dp = 8.dp
}
