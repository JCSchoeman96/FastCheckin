/**
 * Raw color palette primitives for FastCheck.
 *
 * These are the lowest-level color values in the design system. They carry
 * no semantic meaning — naming reflects visual tone, not business intent.
 * Feature screens should never reference these directly; they feed into
 * Material3 color-scheme construction and [ColorRoles].
 *
 * Brand red #D12C26 lives here as a brand primitive, deliberately separate
 * from the error tone family.
 */
package za.co.voelgoed.fastcheck.core.designsystem.tokens

import androidx.compose.ui.graphics.Color

// ── Brand ────────────────────────────────────────────────────────────────────

object BrandPrimitives {
    val Red = Color(0xFFD12C26)
    val RedDark = Color(0xFFA82220)
    val RedLight = Color(0xFFE8635E)
    val RedSubtle = Color(0xFFFDECEB)
}

// ── Neutral ──────────────────────────────────────────────────────────────────

object NeutralPrimitives {
    val White = Color(0xFFFFFFFF)
    val Black = Color(0xFF1A1A1A)
    val N50 = Color(0xFFFAFAFA)
    val N100 = Color(0xFFF5F5F5)
    val N200 = Color(0xFFE5E5E5)
    val N300 = Color(0xFFD4D4D4)
    val N400 = Color(0xFFA3A3A3)
    val N500 = Color(0xFF737373)
    val N600 = Color(0xFF525252)
    val N700 = Color(0xFF404040)
    val N800 = Color(0xFF262626)
    val N900 = Color(0xFF171717)
}

// ── Success ──────────────────────────────────────────────────────────────────

object SuccessPrimitives {
    val Green = Color(0xFF16A34A)
    val GreenDark = Color(0xFF15803D)
    val GreenLight = Color(0xFF4ADE80)
    val GreenSubtle = Color(0xFFDCFCE7)
}

// ── Warning ──────────────────────────────────────────────────────────────────

object WarningPrimitives {
    val Amber = Color(0xFFD97706)
    val AmberDark = Color(0xFFB45309)
    val AmberLight = Color(0xFFFBBF24)
    val AmberSubtle = Color(0xFFFEF3C7)
}

// ── Error ────────────────────────────────────────────────────────────────────

object ErrorPrimitives {
    val Red = Color(0xFFDC2626)
    val RedDark = Color(0xFFB91C1C)
    val RedLight = Color(0xFFF87171)
    val RedSubtle = Color(0xFFFEE2E2)
}

// ── Info ─────────────────────────────────────────────────────────────────────

object InfoPrimitives {
    val Blue = Color(0xFF2563EB)
    val BlueDark = Color(0xFF1D4ED8)
    val BlueLight = Color(0xFF60A5FA)
    val BlueSubtle = Color(0xFFDBEAFE)
}

// ── Muted ────────────────────────────────────────────────────────────────────
// A cool-gray family for low-emphasis or deferred states that should read as
// visually distinct from the warm neutral family above.

object MutedPrimitives {
    val Slate = Color(0xFF64748B)
    val SlateDark = Color(0xFF475569)
    val SlateLight = Color(0xFF94A3B8)
    val SlateSubtle = Color(0xFFF1F5F9)
}
