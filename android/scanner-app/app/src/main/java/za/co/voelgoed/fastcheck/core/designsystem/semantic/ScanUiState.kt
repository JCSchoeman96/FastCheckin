/**
 * Semantic UI state for scan feedback projections.
 *
 * This model keeps UI semantics consistent across scanner-facing and related
 * projection surfaces without coupling UI code to raw runtime result types.
 */
package za.co.voelgoed.fastcheck.core.designsystem.semantic

/**
 * Typed semantic projection for scan feedback.
 *
 * Every semantic state provides:
 * - [tone]: normalized visual severity tone
 * - [iconKey]: stable icon token key
 * - [labelHook]: normalized label/i18n hook
 * - [defaultLabel]: default fallback text
 */
sealed interface ScanUiState {
    val tone: StatusTone
    val iconKey: String
    val labelHook: String
    val defaultLabel: String

    data object Ready : ScanUiState {
        override val tone: StatusTone = StatusTone.Neutral
        override val iconKey: String = "scan_ready"
        override val labelHook: String = "scan.ready"
        override val defaultLabel: String = "Scanner ready."
    }

    data object Processing : ScanUiState {
        override val tone: StatusTone = StatusTone.Info
        override val iconKey: String = "scan_processing"
        override val labelHook: String = "scan.processing"
        override val defaultLabel: String = "Processing scan..."
    }

    data object QueuedLocally : ScanUiState {
        override val tone: StatusTone = StatusTone.Brand
        override val iconKey: String = "scan_queued_local"
        override val labelHook: String = "scan.queued_local"
        override val defaultLabel: String = "Queued locally (pending upload)."
    }

    data object Uploaded : ScanUiState {
        override val tone: StatusTone = StatusTone.Success
        override val iconKey: String = "scan_uploaded"
        override val labelHook: String = "scan.uploaded"
        override val defaultLabel: String = "Accepted by server."
    }

    data object Suppressed : ScanUiState {
        override val tone: StatusTone = StatusTone.Warning
        override val iconKey: String = "scan_suppressed"
        override val labelHook: String = "scan.suppressed.cooldown"
        override val defaultLabel: String = "Capture ignored during active cooldown."
    }

    data object Duplicate : ScanUiState {
        override val tone: StatusTone = StatusTone.Duplicate
        override val iconKey: String = "scan_duplicate"
        override val labelHook: String = "scan.duplicate"
        override val defaultLabel: String = "Scan already processed."
    }

    data object Invalid : ScanUiState {
        override val tone: StatusTone = StatusTone.Warning
        override val iconKey: String = "scan_invalid"
        override val labelHook: String = "scan.invalid"
        override val defaultLabel: String = "Invalid scan data."
    }

    data class OfflineRequired(
        val reason: String? = null
    ) : ScanUiState {
        override val tone: StatusTone = StatusTone.Offline
        override val iconKey: String = "scan_offline_required"
        override val labelHook: String = "scan.offline_required"
        override val defaultLabel: String =
            reason?.takeIf { it.isNotBlank() } ?: "Network or login required."
    }

    data class Failed(
        val reason: String? = null
    ) : ScanUiState {
        override val tone: StatusTone = StatusTone.Destructive
        override val iconKey: String = "scan_failed"
        override val labelHook: String = "scan.failed"
        override val defaultLabel: String =
            reason?.takeIf { it.isNotBlank() } ?: "Could not process scan."
    }

    data class Unknown(
        val detail: String? = null
    ) : ScanUiState {
        override val tone: StatusTone = StatusTone.Muted
        override val iconKey: String = "scan_unknown"
        override val labelHook: String = "scan.unknown"
        override val defaultLabel: String =
            detail?.takeIf { it.isNotBlank() } ?: "Scan outcome unknown."
    }
}
