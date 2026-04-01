/**
 * Status tone vocabulary for FastCheck.
 *
 * Defines the canonical set of status tones (confirmed, warning, error,
 * info, neutral, deferred) that the semantic layer uses to drive color,
 * icon, and label selection across all status surfaces.
 *
 * This is the foundation that domain-specific UI state files
 * (ScanUiState, SyncUiState, etc.) map into.
 */
package za.co.voelgoed.fastcheck.core.designsystem.semantic

/**
 * Typed semantic vocabulary for status-driven UI.
 *
 * This intentionally models tone only; domain/business state mapping
 * remains in dedicated semantic state files.
 */
enum class StatusTone {
    Neutral,
    Brand,
    Success,
    Warning,
    Info,
    Destructive,
    Duplicate,
    Offline,
    Muted,
}
