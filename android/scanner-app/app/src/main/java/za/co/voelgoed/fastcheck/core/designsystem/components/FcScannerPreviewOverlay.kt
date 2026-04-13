/**
 * Lightweight visual overlay for the camera preview on the scan screen.
 */
package za.co.voelgoed.fastcheck.core.designsystem.components

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import za.co.voelgoed.fastcheck.core.designsystem.semantic.StatusTone
import za.co.voelgoed.fastcheck.core.designsystem.theme.fastCheck
import za.co.voelgoed.fastcheck.core.designsystem.tokens.StrokeTokens

object FcScannerPreviewOverlayTestTags {
    const val Reticle = "fc_scanner_preview_overlay_reticle"
}

@Composable
fun FcScannerPreviewOverlay(
    modifier: Modifier = Modifier,
    statusLabel: String? = null,
    statusTone: StatusTone = StatusTone.Info,
    showReticle: Boolean = true,
) {
    val theme = MaterialTheme.fastCheck
    val accent = theme.statusRoles.resolve(statusTone)

    Box(modifier = modifier.fillMaxSize()) {
        if (!statusLabel.isNullOrBlank()) {
            Surface(
                modifier =
                    Modifier
                        .align(Alignment.TopCenter)
                        .padding(top = theme.spacing.medium),
                shape = theme.shapes.extraLarge,
                color = theme.colorScheme.surface.copy(alpha = 0.88f),
                contentColor = theme.colorScheme.onSurface,
                border = BorderStroke(StrokeTokens.Hairline, accent.copy(alpha = 0.28f)),
                shadowElevation = theme.elevation.low,
            ) {
                Text(
                    text = statusLabel.uppercase(),
                    style = theme.typography.labelLarge,
                    fontWeight = FontWeight.Bold,
                    modifier =
                        Modifier.padding(
                            horizontal = theme.spacing.large,
                            vertical = theme.spacing.small,
                        ),
                )
            }
        }

        if (showReticle) {
            ReticleFrame(
                accent = accent,
                modifier =
                    Modifier
                        .align(Alignment.Center)
                        .fillMaxSize()
                        .padding(horizontal = 40.dp, vertical = 36.dp)
                        .testTag(FcScannerPreviewOverlayTestTags.Reticle),
            )
        }
    }
}

@Composable
private fun BoxScope.ReticleFrame(
    accent: Color,
    modifier: Modifier = Modifier,
) {
    Box(modifier = modifier) {
        CornerBracket(
            accent = accent,
            alignTop = true,
            alignStart = true,
            modifier = Modifier.align(Alignment.TopStart),
        )
        CornerBracket(
            accent = accent,
            alignTop = true,
            alignStart = false,
            modifier = Modifier.align(Alignment.TopEnd),
        )
        CornerBracket(
            accent = accent,
            alignTop = false,
            alignStart = true,
            modifier = Modifier.align(Alignment.BottomStart),
        )
        CornerBracket(
            accent = accent,
            alignTop = false,
            alignStart = false,
            modifier = Modifier.align(Alignment.BottomEnd),
        )
    }
}

@Composable
private fun CornerBracket(
    accent: Color,
    alignTop: Boolean,
    alignStart: Boolean,
    modifier: Modifier = Modifier,
) {
    Box(modifier = modifier.size(40.dp)) {
        val barAlignment =
            when {
                alignTop && alignStart -> Alignment.TopStart
                alignTop && !alignStart -> Alignment.TopEnd
                !alignTop && alignStart -> Alignment.BottomStart
                else -> Alignment.BottomEnd
            }

        Box(
            modifier =
                Modifier
                    .align(barAlignment)
                    .width(32.dp)
                    .height(4.dp)
                    .background(accent),
        )

        Box(
            modifier =
                Modifier
                    .align(barAlignment)
                    .width(4.dp)
                    .height(32.dp)
                    .background(accent),
        )
    }
}
