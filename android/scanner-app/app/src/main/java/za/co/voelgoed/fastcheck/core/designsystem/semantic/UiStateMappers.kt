/**
 * Shared mapping utilities for semantic UI state.
 *
 * Scanner-facing mappings must remain truthful to currently surfaced runtime
 * types. Richer queue/flush semantics are exposed as helper projections only
 * and are intentionally separate from immediate scanner handoff mapping.
 */
package za.co.voelgoed.fastcheck.core.designsystem.semantic

import za.co.voelgoed.fastcheck.domain.model.FlushItemOutcome
import za.co.voelgoed.fastcheck.domain.model.FlushItemResult
import za.co.voelgoed.fastcheck.domain.model.QueueCreationResult
import za.co.voelgoed.fastcheck.feature.scanning.usecase.CaptureHandoffResult

/**
 * Immediate scanner-facing projection.
 *
 * This maps only what [CaptureHandoffResult] can currently express:
 * accepted, cooldown suppression, and failed(reason).
 */
fun CaptureHandoffResult.toScanUiState(): ScanUiState =
    when (this) {
        CaptureHandoffResult.Accepted -> ScanUiState.QueuedLocally
        CaptureHandoffResult.SuppressedByCooldown -> ScanUiState.Suppressed
        is CaptureHandoffResult.Failed -> classifyCaptureFailure(reason)
    }

/**
 * Optional helper projection for queue results.
 *
 * Not used by the immediate scanner handoff path in this phase.
 */
fun QueueCreationResult.toQueueScanUiState(): ScanUiState =
    when (this) {
        is QueueCreationResult.Enqueued -> ScanUiState.QueuedLocally
        QueueCreationResult.ReplaySuppressed -> ScanUiState.Duplicate
        QueueCreationResult.InvalidTicketCode -> ScanUiState.Invalid
        QueueCreationResult.MissingSessionContext ->
            ScanUiState.OfflineRequired("Login is required before scans can be queued.")
    }

/**
 * Optional helper projection for flush item outcomes.
 *
 * Not used by the immediate scanner handoff path in this phase.
 */
fun FlushItemResult.toFlushScanUiState(): ScanUiState {
    val normalizedReason = reasonCode.normalizeReasonCode()

    return when (outcome) {
        FlushItemOutcome.SUCCESS -> ScanUiState.Uploaded
        FlushItemOutcome.DUPLICATE -> ScanUiState.Duplicate
        FlushItemOutcome.RETRYABLE_FAILURE -> ScanUiState.OfflineRequired(message)
        FlushItemOutcome.AUTH_EXPIRED -> ScanUiState.OfflineRequired(message)
        FlushItemOutcome.TERMINAL_ERROR ->
            when (normalizedReason) {
                "payment_invalid" -> ScanUiState.Invalid
                "business_duplicate", "replay_duplicate" -> ScanUiState.Duplicate
                null -> ScanUiState.Unknown(message)
                else -> ScanUiState.Failed(message)
            }
    }
}

private fun classifyCaptureFailure(reason: String): ScanUiState {
    val trimmed = reason.trim()
    if (trimmed.isEmpty()) return ScanUiState.Failed()

    val normalized = trimmed.lowercase()
    return when {
        normalized.contains("offline") ||
            normalized.contains("network") ||
            normalized.contains("timeout") ||
            normalized.contains("session expired") ||
            normalized.contains("auth expired") ||
            normalized.contains("login required") ->
            ScanUiState.OfflineRequired(trimmed)
        else ->
            ScanUiState.Failed(trimmed)
    }
}

private fun String?.normalizeReasonCode(): String? =
    this
        ?.trim()
        ?.lowercase()
        ?.takeIf { it.isNotBlank() }
