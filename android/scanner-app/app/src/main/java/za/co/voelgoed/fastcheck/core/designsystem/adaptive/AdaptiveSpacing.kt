/**
 * Adaptive spacing scaling.
 *
 * Adjusts a bounded set of spacing tokens based on the current
 * [WindowBuckets] classification. The helper stays explicit and value-object
 * based so the API remains easy to reason about later.
 */
package za.co.voelgoed.fastcheck.core.designsystem.adaptive

import androidx.compose.runtime.Immutable
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import za.co.voelgoed.fastcheck.core.designsystem.tokens.SpacingTokens

@Immutable
data class AdaptiveSpacingValues(
    val none: Dp,
    val xxSmall: Dp,
    val xSmall: Dp,
    val small: Dp,
    val medium: Dp,
    val large: Dp,
    val xLarge: Dp,
    val xxLarge: Dp,
    val section: Dp,
)

fun adaptiveSpacing(windowBuckets: WindowBuckets): AdaptiveSpacingValues =
    when (windowBuckets.width) {
        WindowBucket.Compact -> compactSpacing()
        WindowBucket.Standard -> standardSpacing()
        WindowBucket.Expanded -> expandedSpacing()
    }

private fun compactSpacing(): AdaptiveSpacingValues =
    AdaptiveSpacingValues(
        none = SpacingTokens.None,
        xxSmall = SpacingTokens.XXSmall,
        xSmall = SpacingTokens.XSmall,
        small = SpacingTokens.Small,
        medium = SpacingTokens.Medium,
        large = SpacingTokens.Large,
        xLarge = SpacingTokens.XLarge,
        xxLarge = SpacingTokens.XXLarge,
        section = SpacingTokens.Section,
    )

private fun standardSpacing(): AdaptiveSpacingValues =
    AdaptiveSpacingValues(
        none = SpacingTokens.None,
        xxSmall = SpacingTokens.XXSmall,
        xSmall = SpacingTokens.XSmall,
        small = SpacingTokens.Small,
        medium = 14.dp,
        large = 18.dp,
        xLarge = 26.dp,
        xxLarge = 34.dp,
        section = 52.dp,
    )

private fun expandedSpacing(): AdaptiveSpacingValues =
    AdaptiveSpacingValues(
        none = SpacingTokens.None,
        xxSmall = SpacingTokens.XXSmall,
        xSmall = SpacingTokens.XSmall,
        small = SpacingTokens.Small,
        medium = 16.dp,
        large = 20.dp,
        xLarge = 28.dp,
        xxLarge = 36.dp,
        section = 56.dp,
    )
