/**
 * Status tone vocabulary for FastCheck.
 *
 * Defines the canonical tone language for all semantic UI state surfaces.
 * Domain-specific models (scan, sync, payment, attendance) should map into
 * this shared vocabulary instead of introducing parallel tone enums.
 *
 * This is the foundation that domain-specific UI state files
 * (ScanUiState, SyncUiState, etc.) map into.
 */
package za.co.voelgoed.fastcheck.core.designsystem.semantic

enum class StatusTone {
    Neutral,
    Brand,
    Success,
    Warning,
    Info,
    Destructive,
    Duplicate,
    Offline,
    Muted
}
