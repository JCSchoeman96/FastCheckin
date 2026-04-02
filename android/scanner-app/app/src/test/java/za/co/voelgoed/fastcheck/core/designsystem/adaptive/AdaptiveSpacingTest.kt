package za.co.voelgoed.fastcheck.core.designsystem.adaptive

import androidx.compose.ui.unit.dp
import com.google.common.truth.Truth.assertThat
import org.junit.Test
import za.co.voelgoed.fastcheck.core.designsystem.tokens.SpacingTokens

class AdaptiveSpacingTest {
    @Test
    fun compactSpacingMatchesTheBaseTokens() {
        assertThat(adaptiveSpacing(WindowBuckets(WindowBucket.Compact))).isEqualTo(
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
        )
    }

    @Test
    fun standardSpacingUsesTheFirstExplicitStepUp() {
        assertThat(adaptiveSpacing(WindowBuckets(WindowBucket.Standard))).isEqualTo(
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
        )
    }

    @Test
    fun expandedSpacingUsesTheSecondExplicitStepUp() {
        assertThat(adaptiveSpacing(WindowBuckets(WindowBucket.Expanded))).isEqualTo(
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
        )
    }
}
