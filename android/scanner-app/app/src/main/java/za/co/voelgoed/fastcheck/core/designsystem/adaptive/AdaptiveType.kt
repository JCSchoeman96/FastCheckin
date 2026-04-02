/**
 * Adaptive typography scaling.
 *
 * Adjusts a bounded subset of typography tokens based on the current
 * [WindowBuckets] classification. The helper stays explicit so the design
 * system does not drift into generic responsive math.
 */
package za.co.voelgoed.fastcheck.core.designsystem.adaptive

import androidx.compose.material3.Typography
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.unit.sp
import za.co.voelgoed.fastcheck.core.designsystem.tokens.FastCheckTypography

fun adaptiveTypography(windowBuckets: WindowBuckets): Typography =
    when (windowBuckets.width) {
        WindowBucket.Compact -> FastCheckTypography
        WindowBucket.Standard -> FastCheckTypography.withAdaptiveSubset(
            displayMedium = 25.sp,
            displayMediumLineHeight = 31.sp,
            displaySmall = 21.sp,
            displaySmallLineHeight = 27.sp,
            headlineLarge = 19.sp,
            headlineLargeLineHeight = 25.sp,
            titleLarge = 19.sp,
            titleLargeLineHeight = 25.sp,
            bodyLarge = 17.sp,
            bodyLargeLineHeight = 25.sp,
        )
        WindowBucket.Expanded -> FastCheckTypography.withAdaptiveSubset(
            displayMedium = 26.sp,
            displayMediumLineHeight = 32.sp,
            displaySmall = 22.sp,
            displaySmallLineHeight = 28.sp,
            headlineLarge = 20.sp,
            headlineLargeLineHeight = 26.sp,
            titleLarge = 20.sp,
            titleLargeLineHeight = 26.sp,
            bodyLarge = 18.sp,
            bodyLargeLineHeight = 26.sp,
        )
    }

private fun Typography.withAdaptiveSubset(
    displayMedium: androidx.compose.ui.unit.TextUnit,
    displayMediumLineHeight: androidx.compose.ui.unit.TextUnit,
    displaySmall: androidx.compose.ui.unit.TextUnit,
    displaySmallLineHeight: androidx.compose.ui.unit.TextUnit,
    headlineLarge: androidx.compose.ui.unit.TextUnit,
    headlineLargeLineHeight: androidx.compose.ui.unit.TextUnit,
    titleLarge: androidx.compose.ui.unit.TextUnit,
    titleLargeLineHeight: androidx.compose.ui.unit.TextUnit,
    bodyLarge: androidx.compose.ui.unit.TextUnit,
    bodyLargeLineHeight: androidx.compose.ui.unit.TextUnit,
): Typography =
    copy(
        displayMedium = this.displayMedium.adapt(fontSize = displayMedium, lineHeight = displayMediumLineHeight),
        displaySmall = this.displaySmall.adapt(fontSize = displaySmall, lineHeight = displaySmallLineHeight),
        headlineLarge = this.headlineLarge.adapt(fontSize = headlineLarge, lineHeight = headlineLargeLineHeight),
        titleLarge = this.titleLarge.adapt(fontSize = titleLarge, lineHeight = titleLargeLineHeight),
        bodyLarge = this.bodyLarge.adapt(fontSize = bodyLarge, lineHeight = bodyLargeLineHeight),
    )

private fun TextStyle.adapt(
    fontSize: androidx.compose.ui.unit.TextUnit,
    lineHeight: androidx.compose.ui.unit.TextUnit,
): TextStyle =
    copy(
        fontSize = fontSize,
        lineHeight = lineHeight,
    )
