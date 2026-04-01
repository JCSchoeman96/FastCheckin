/**
 * Gradient tokens for FastCheck.
 *
 * Sparse, functional gradients for scanner-surface overlays and subtle
 * background effects. No decorative excess.
 */
package za.co.voelgoed.fastcheck.core.designsystem.tokens

import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color

object GradientTokens {
    val ScrimTop: Brush = Brush.verticalGradient(
        colors = listOf(Color(0xCC000000), Color.Transparent),
    )

    val ScrimBottom: Brush = Brush.verticalGradient(
        colors = listOf(Color.Transparent, Color(0xCC000000)),
    )

    val SurfaceFade: Brush = Brush.verticalGradient(
        colors = listOf(Color.Transparent, Color(0x0D000000)),
    )
}
