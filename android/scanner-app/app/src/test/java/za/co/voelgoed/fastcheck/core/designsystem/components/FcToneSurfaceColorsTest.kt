package za.co.voelgoed.fastcheck.core.designsystem.components

import androidx.compose.ui.graphics.Color
import com.google.common.truth.Truth.assertThat
import org.junit.Test

class FcToneSurfaceColorsTest {
    @Test
    fun contentColorMatchesAccent() {
        val accent = Color(0xFFD12C26)

        val colors = resolveToneSurfaceColors(accent, containerAlpha = 0.08f)

        assertThat(colors.contentColor).isEqualTo(accent)
    }

    @Test
    fun containerColorUsesRequestedAlpha() {
        val accent = Color(0xFF2563EB)

        val colors = resolveToneSurfaceColors(accent, containerAlpha = 0.12f)

        assertThat(colors.containerColor).isEqualTo(accent.copy(alpha = 0.12f))
    }

    @Test
    fun borderAlphaDefaultsToContainerAlpha() {
        val accent = Color(0xFF16A34A)

        val colors = resolveToneSurfaceColors(accent, containerAlpha = 0.08f)

        assertThat(colors.borderColor).isEqualTo(accent.copy(alpha = 0.08f))
    }

    @Test
    fun borderAlphaOverrideUsesExplicitValue() {
        val accent = Color(0xFFD97706)

        val colors = resolveToneSurfaceColors(
            accent = accent,
            containerAlpha = 0.08f,
            borderAlpha = 0.24f,
        )

        assertThat(colors.borderColor).isEqualTo(accent.copy(alpha = 0.24f))
    }
}
