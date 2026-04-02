package za.co.voelgoed.fastcheck.core.designsystem.adaptive

import com.google.common.truth.Truth.assertThat
import org.junit.Test
import za.co.voelgoed.fastcheck.core.designsystem.tokens.FastCheckTypography
import androidx.compose.ui.unit.sp

class AdaptiveTypeTest {
    @Test
    fun compactTypographyMatchesTheBaseTokens() {
        assertThat(adaptiveTypography(WindowBuckets(WindowBucket.Compact))).isEqualTo(FastCheckTypography)
    }

    @Test
    fun standardTypographyAdjustsOnlyTheNamedSubset() {
        val typography = adaptiveTypography(WindowBuckets(WindowBucket.Standard))

        assertThat(typography.displayMedium.fontSize).isEqualTo(25.sp)
        assertThat(typography.displayMedium.lineHeight).isEqualTo(31.sp)
        assertThat(typography.displaySmall.fontSize).isEqualTo(21.sp)
        assertThat(typography.displaySmall.lineHeight).isEqualTo(27.sp)
        assertThat(typography.headlineLarge.fontSize).isEqualTo(19.sp)
        assertThat(typography.headlineLarge.lineHeight).isEqualTo(25.sp)
        assertThat(typography.titleLarge.fontSize).isEqualTo(19.sp)
        assertThat(typography.titleLarge.lineHeight).isEqualTo(25.sp)
        assertThat(typography.bodyLarge.fontSize).isEqualTo(17.sp)
        assertThat(typography.bodyLarge.lineHeight).isEqualTo(25.sp)

        assertThat(typography.displayLarge).isEqualTo(FastCheckTypography.displayLarge)
        assertThat(typography.bodyMedium).isEqualTo(FastCheckTypography.bodyMedium)
    }

    @Test
    fun expandedTypographyAppliesTheSecondBoundedStepUp() {
        val typography = adaptiveTypography(WindowBuckets(WindowBucket.Expanded))

        assertThat(typography.displayMedium.fontSize).isEqualTo(26.sp)
        assertThat(typography.displayMedium.lineHeight).isEqualTo(32.sp)
        assertThat(typography.displaySmall.fontSize).isEqualTo(22.sp)
        assertThat(typography.displaySmall.lineHeight).isEqualTo(28.sp)
        assertThat(typography.headlineLarge.fontSize).isEqualTo(20.sp)
        assertThat(typography.headlineLarge.lineHeight).isEqualTo(26.sp)
        assertThat(typography.titleLarge.fontSize).isEqualTo(20.sp)
        assertThat(typography.titleLarge.lineHeight).isEqualTo(26.sp)
        assertThat(typography.bodyLarge.fontSize).isEqualTo(18.sp)
        assertThat(typography.bodyLarge.lineHeight).isEqualTo(26.sp)

        assertThat(typography.displayLarge).isEqualTo(FastCheckTypography.displayLarge)
        assertThat(typography.bodyMedium).isEqualTo(FastCheckTypography.bodyMedium)
    }
}
