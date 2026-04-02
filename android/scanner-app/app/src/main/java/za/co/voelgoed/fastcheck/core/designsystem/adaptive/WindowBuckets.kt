/**
 * Window-size buckets for adaptive layouts.
 *
 * Classifies the current window into compact/standard/expanded buckets for
 * bounded responsive styling. The model stays intentionally small and
 * explicit so later UI work can consume it without a generalized engine.
 */
package za.co.voelgoed.fastcheck.core.designsystem.adaptive

import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

enum class WindowBucket {
    Compact,
    Standard,
    Expanded,
}

data class WindowBuckets(
    val width: WindowBucket,
) {
    val isCompact: Boolean
        get() = width == WindowBucket.Compact

    val isStandard: Boolean
        get() = width == WindowBucket.Standard

    val isExpanded: Boolean
        get() = width == WindowBucket.Expanded

    companion object {
        fun fromWidth(widthDp: Dp): WindowBuckets = WindowBuckets(bucketForWidth(widthDp))
    }
}

fun bucketForWidth(widthDp: Dp): WindowBucket =
    when {
        widthDp < 600.dp -> WindowBucket.Compact
        widthDp < 840.dp -> WindowBucket.Standard
        else -> WindowBucket.Expanded
    }
