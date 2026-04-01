/**
 * Shape tokens for FastCheck.
 *
 * Corner-radius scale for surfaces used in the scanner app. Sized for
 * pills (fully rounded), cards, buttons, and chips.
 */
package za.co.voelgoed.fastcheck.core.designsystem.tokens

import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.unit.dp

object ShapeTokens {
    val None = RoundedCornerShape(0.dp)
    val Small = RoundedCornerShape(4.dp)
    val Medium = RoundedCornerShape(8.dp)
    val Large = RoundedCornerShape(12.dp)
    val XLarge = RoundedCornerShape(16.dp)
    val Pill = RoundedCornerShape(percent = 50)
}
