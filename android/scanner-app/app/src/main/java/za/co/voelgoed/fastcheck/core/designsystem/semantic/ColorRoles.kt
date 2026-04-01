/**
 * Semantic color roles for FastCheck.
 *
 * Maps logical UI intents (success, warning, error, info, neutral) to
 * concrete color tokens from [ColorPrimitives]. Feature screens consume
 * these roles rather than raw Color values.
 *
 * Brand red (#D12C26) is a brand token, not the universal destructive
 * or error color.
 */
package za.co.voelgoed.fastcheck.core.designsystem.semantic

import androidx.compose.runtime.Immutable
import androidx.compose.ui.graphics.Color
import za.co.voelgoed.fastcheck.core.designsystem.tokens.BrandPrimitives
import za.co.voelgoed.fastcheck.core.designsystem.tokens.ErrorPrimitives
import za.co.voelgoed.fastcheck.core.designsystem.tokens.InfoPrimitives
import za.co.voelgoed.fastcheck.core.designsystem.tokens.MutedPrimitives
import za.co.voelgoed.fastcheck.core.designsystem.tokens.NeutralPrimitives
import za.co.voelgoed.fastcheck.core.designsystem.tokens.SuccessPrimitives
import za.co.voelgoed.fastcheck.core.designsystem.tokens.WarningPrimitives

@Immutable
data class StatusRoleColors(
    val container: Color,
    val content: Color,
    val border: Color,
)

@Immutable
data class StatusColorRoles(
    val neutral: StatusRoleColors,
    val brand: StatusRoleColors,
    val success: StatusRoleColors,
    val warning: StatusRoleColors,
    val info: StatusRoleColors,
    val destructive: StatusRoleColors,
    val duplicate: StatusRoleColors,
    val offline: StatusRoleColors,
    val muted: StatusRoleColors,
) {
    fun forTone(tone: StatusTone): StatusRoleColors =
        when (tone) {
            StatusTone.Neutral -> neutral
            StatusTone.Brand -> brand
            StatusTone.Success -> success
            StatusTone.Warning -> warning
            StatusTone.Info -> info
            StatusTone.Destructive -> destructive
            StatusTone.Duplicate -> duplicate
            StatusTone.Offline -> offline
            StatusTone.Muted -> muted
        }
}

@Immutable
data class ColorRoles(
    val brand: Color,
    val interactivePrimary: Color,
    val interactiveSecondary: Color,
    val success: Color,
    val warning: Color,
    val info: Color,
    val destructive: Color,
    val muted: Color,
    val borderSubtle: Color,
    val borderStrong: Color,
    val textPrimary: Color,
    val textSecondary: Color,
    val textInverse: Color,
    val surfaceBase: Color,
    val surfaceRaised: Color,
    val surfaceMuted: Color,
    val status: StatusColorRoles,
)

fun lightColorRoles(): ColorRoles =
    ColorRoles(
        brand = BrandPrimitives.Red,
        interactivePrimary = BrandPrimitives.Red,
        interactiveSecondary = BrandPrimitives.RedDark,
        success = SuccessPrimitives.Green,
        warning = WarningPrimitives.Amber,
        info = InfoPrimitives.Blue,
        destructive = ErrorPrimitives.Red,
        muted = MutedPrimitives.Slate,
        borderSubtle = NeutralPrimitives.N200,
        borderStrong = NeutralPrimitives.N400,
        textPrimary = NeutralPrimitives.N900,
        textSecondary = NeutralPrimitives.N600,
        textInverse = NeutralPrimitives.White,
        surfaceBase = NeutralPrimitives.White,
        surfaceRaised = NeutralPrimitives.N50,
        surfaceMuted = NeutralPrimitives.N100,
        status = StatusColorRoles(
            neutral = StatusRoleColors(
                container = NeutralPrimitives.N100,
                content = NeutralPrimitives.N800,
                border = NeutralPrimitives.N200,
            ),
            brand = StatusRoleColors(
                container = BrandPrimitives.RedSubtle,
                content = BrandPrimitives.RedDark,
                border = BrandPrimitives.RedLight,
            ),
            success = StatusRoleColors(
                container = SuccessPrimitives.GreenSubtle,
                content = SuccessPrimitives.GreenDark,
                border = SuccessPrimitives.GreenLight,
            ),
            warning = StatusRoleColors(
                container = WarningPrimitives.AmberSubtle,
                content = WarningPrimitives.AmberDark,
                border = WarningPrimitives.AmberLight,
            ),
            info = StatusRoleColors(
                container = InfoPrimitives.BlueSubtle,
                content = InfoPrimitives.BlueDark,
                border = InfoPrimitives.BlueLight,
            ),
            destructive = StatusRoleColors(
                container = ErrorPrimitives.RedSubtle,
                content = ErrorPrimitives.RedDark,
                border = ErrorPrimitives.RedLight,
            ),
            duplicate = StatusRoleColors(
                container = WarningPrimitives.AmberSubtle,
                content = WarningPrimitives.AmberDark,
                border = WarningPrimitives.AmberLight,
            ),
            offline = StatusRoleColors(
                container = MutedPrimitives.SlateSubtle,
                content = MutedPrimitives.SlateDark,
                border = MutedPrimitives.SlateLight,
            ),
            muted = StatusRoleColors(
                container = NeutralPrimitives.N100,
                content = NeutralPrimitives.N600,
                border = NeutralPrimitives.N200,
            ),
        ),
    )
