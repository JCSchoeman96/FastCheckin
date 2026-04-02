package za.co.voelgoed.fastcheck.core.designsystem.components

import androidx.compose.ui.graphics.Color

internal data class FcToneSurfaceColors(
    val containerColor: Color,
    val contentColor: Color,
    val borderColor: Color,
)

internal fun resolveToneSurfaceColors(
    accent: Color,
    containerAlpha: Float,
    borderAlpha: Float = containerAlpha,
): FcToneSurfaceColors =
    FcToneSurfaceColors(
        containerColor = accent.copy(alpha = containerAlpha),
        contentColor = accent,
        borderColor = accent.copy(alpha = borderAlpha),
    )
