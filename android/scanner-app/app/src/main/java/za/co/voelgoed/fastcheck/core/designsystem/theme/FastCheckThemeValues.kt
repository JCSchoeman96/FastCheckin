package za.co.voelgoed.fastcheck.core.designsystem.theme

import androidx.compose.material3.ColorScheme
import androidx.compose.material3.Shapes
import androidx.compose.material3.Typography
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Immutable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.Dp
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
import za.co.voelgoed.fastcheck.core.designsystem.tokens.FastCheckTypography

@Immutable
data class FastCheckSpacing(
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

@Immutable
data class FastCheckElevation(
    val none: Dp,
    val low: Dp,
    val medium: Dp,
    val high: Dp,
    val overlay: Dp,
)

@Immutable
data class FastCheckStatusRoles(
    val neutral: Color,
    val brand: Color,
    val success: Color,
    val warning: Color,
    val info: Color,
    val destructive: Color,
    val duplicate: Color,
    val offline: Color,
    val muted: Color,
) {
    fun resolve(tone: StatusTone): Color =
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
data class FastCheckThemeValues(
    val colorScheme: ColorScheme,
    val typography: Typography,
    val shapes: Shapes,
    val spacing: FastCheckSpacing,
    val elevation: FastCheckElevation,
    val statusRoles: FastCheckStatusRoles,
)

internal fun buildFastCheckThemeValues(): FastCheckThemeValues =
    FastCheckThemeValues(
        colorScheme = buildFastCheckColorScheme(),
        typography = FastCheckTypography,
        shapes =
            Shapes(
                extraSmall = ShapeTokens.Small,
                small = ShapeTokens.Medium,
                medium = ShapeTokens.Large,
                large = ShapeTokens.XLarge,
                extraLarge = ShapeTokens.Pill,
            ),
        spacing =
            FastCheckSpacing(
                none = SpacingTokens.None,
                xxSmall = SpacingTokens.XXSmall,
                xSmall = SpacingTokens.XSmall,
                small = SpacingTokens.Small,
                medium = SpacingTokens.Medium,
                large = SpacingTokens.Large,
                xLarge = SpacingTokens.XLarge,
                xxLarge = SpacingTokens.XXLarge,
                section = SpacingTokens.Section,
            ),
        elevation =
            FastCheckElevation(
                none = ElevationTokens.None,
                low = ElevationTokens.Low,
                medium = ElevationTokens.Medium,
                high = ElevationTokens.High,
                overlay = ElevationTokens.Overlay,
            ),
        statusRoles =
            FastCheckStatusRoles(
                neutral = NeutralPrimitives.N700,
                brand = BrandPrimitives.Red,
                success = SuccessPrimitives.Green,
                warning = WarningPrimitives.Amber,
                info = InfoPrimitives.Blue,
                destructive = ErrorPrimitives.Red,
                duplicate = BrandPrimitives.RedLight,
                offline = MutedPrimitives.SlateDark,
                muted = MutedPrimitives.Slate,
            ),
    )

internal fun buildFastCheckColorScheme(): ColorScheme =
    lightColorScheme(
        primary = BrandPrimitives.Red,
        onPrimary = NeutralPrimitives.White,
        primaryContainer = BrandPrimitives.RedSubtle,
        onPrimaryContainer = BrandPrimitives.RedDark,
        secondary = NeutralPrimitives.N700,
        onSecondary = NeutralPrimitives.White,
        secondaryContainer = NeutralPrimitives.N100,
        onSecondaryContainer = NeutralPrimitives.N900,
        tertiary = InfoPrimitives.Blue,
        onTertiary = NeutralPrimitives.White,
        tertiaryContainer = InfoPrimitives.BlueSubtle,
        onTertiaryContainer = InfoPrimitives.BlueDark,
        error = ErrorPrimitives.Red,
        onError = NeutralPrimitives.White,
        errorContainer = ErrorPrimitives.RedSubtle,
        onErrorContainer = ErrorPrimitives.RedDark,
        background = NeutralPrimitives.N50,
        onBackground = NeutralPrimitives.N900,
        surface = NeutralPrimitives.White,
        onSurface = NeutralPrimitives.N900,
        surfaceVariant = NeutralPrimitives.N100,
        onSurfaceVariant = NeutralPrimitives.N600,
        outline = NeutralPrimitives.N300,
        outlineVariant = NeutralPrimitives.N200,
        scrim = NeutralPrimitives.Black.copy(alpha = 0.60f),
        inverseSurface = NeutralPrimitives.N900,
        inverseOnSurface = NeutralPrimitives.N50,
        inversePrimary = BrandPrimitives.RedLight,
        surfaceDim = NeutralPrimitives.N100,
        surfaceBright = NeutralPrimitives.White,
        surfaceContainerLowest = NeutralPrimitives.White,
        surfaceContainerLow = NeutralPrimitives.N50,
        surfaceContainer = NeutralPrimitives.N100,
        surfaceContainerHigh = NeutralPrimitives.N200,
        surfaceContainerHighest = NeutralPrimitives.N300,
    )
