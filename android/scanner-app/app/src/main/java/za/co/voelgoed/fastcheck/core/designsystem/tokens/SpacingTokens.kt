/**
 * Spacing scale tokens for FastCheck.
 *
 * A disciplined set of Dp spacing values grounded in the existing scaffold
 * layout conventions (4dp, 8dp, 12dp, 24dp). The scale uses a base-4
 * progression with a few practical half-steps.
 */
package za.co.voelgoed.fastcheck.core.designsystem.tokens

import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

object SpacingTokens {
    val None: Dp = 0.dp
    val XXSmall: Dp = 2.dp
    val XSmall: Dp = 4.dp
    val Small: Dp = 8.dp
    val Medium: Dp = 12.dp
    val Large: Dp = 16.dp
    val XLarge: Dp = 24.dp
    val XXLarge: Dp = 32.dp
    val Section: Dp = 48.dp
}
