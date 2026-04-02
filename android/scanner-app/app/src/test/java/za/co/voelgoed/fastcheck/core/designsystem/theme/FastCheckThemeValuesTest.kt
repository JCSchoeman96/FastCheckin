package za.co.voelgoed.fastcheck.core.designsystem.theme

import com.google.common.truth.Truth.assertThat
import org.junit.Test
import za.co.voelgoed.fastcheck.core.designsystem.semantic.StatusTone
import za.co.voelgoed.fastcheck.core.designsystem.tokens.BrandPrimitives
import za.co.voelgoed.fastcheck.core.designsystem.tokens.ElevationTokens
import za.co.voelgoed.fastcheck.core.designsystem.tokens.ErrorPrimitives
import za.co.voelgoed.fastcheck.core.designsystem.tokens.InfoPrimitives
import za.co.voelgoed.fastcheck.core.designsystem.tokens.MutedPrimitives
import za.co.voelgoed.fastcheck.core.designsystem.tokens.NeutralPrimitives
import za.co.voelgoed.fastcheck.core.designsystem.tokens.ShapeTokens
import za.co.voelgoed.fastcheck.core.designsystem.tokens.SpacingTokens
import za.co.voelgoed.fastcheck.core.designsystem.tokens.SuccessPrimitives
import za.co.voelgoed.fastcheck.core.designsystem.tokens.WarningPrimitives

class FastCheckThemeValuesTest {
    @Test
    fun themeValuesAreAssembledFromExistingTokens() {
        val values = buildFastCheckThemeValues()

        assertThat(values.colorScheme.primary).isEqualTo(BrandPrimitives.Red)
        assertThat(values.colorScheme.onSurface).isEqualTo(NeutralPrimitives.N900)
        assertThat(values.typography).isEqualTo(za.co.voelgoed.fastcheck.core.designsystem.tokens.FastCheckTypography)
        assertThat(values.shapes.extraSmall).isEqualTo(ShapeTokens.Small)
        assertThat(values.shapes.large).isEqualTo(ShapeTokens.XLarge)
        assertThat(values.spacing.small).isEqualTo(SpacingTokens.Small)
        assertThat(values.spacing.section).isEqualTo(SpacingTokens.Section)
        assertThat(values.elevation.overlay).isEqualTo(ElevationTokens.Overlay)
    }

    @Test
    fun statusToneResolvesToExpectedRoleColor() {
        val roles = buildFastCheckThemeValues().statusRoles

        assertThat(roles.resolve(StatusTone.Neutral)).isEqualTo(NeutralPrimitives.N700)
        assertThat(roles.resolve(StatusTone.Brand)).isEqualTo(BrandPrimitives.Red)
        assertThat(roles.resolve(StatusTone.Success)).isEqualTo(SuccessPrimitives.Green)
        assertThat(roles.resolve(StatusTone.Warning)).isEqualTo(WarningPrimitives.Amber)
        assertThat(roles.resolve(StatusTone.Info)).isEqualTo(InfoPrimitives.Blue)
        assertThat(roles.resolve(StatusTone.Destructive)).isEqualTo(ErrorPrimitives.Red)
        assertThat(roles.resolve(StatusTone.Duplicate)).isEqualTo(BrandPrimitives.RedLight)
        assertThat(roles.resolve(StatusTone.Offline)).isEqualTo(MutedPrimitives.SlateDark)
        assertThat(roles.resolve(StatusTone.Muted)).isEqualTo(MutedPrimitives.Slate)
    }
}
