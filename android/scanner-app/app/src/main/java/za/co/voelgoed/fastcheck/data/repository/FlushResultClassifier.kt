package za.co.voelgoed.fastcheck.data.repository

import javax.inject.Inject
import javax.inject.Singleton
import za.co.voelgoed.fastcheck.data.remote.UploadedScanResult
import za.co.voelgoed.fastcheck.domain.model.FlushItemOutcome
import za.co.voelgoed.fastcheck.domain.model.FlushItemResult
import za.co.voelgoed.fastcheck.domain.model.PendingScan

/**
 * Isolates the current Phoenix mobile API's additive scan-result semantics.
 * Row presence plus status remain authoritative for retry vs terminal
 * handling; optional reason codes only refine persisted detail.
 */
@Singleton
class FlushResultClassifier @Inject constructor() {
    fun classify(
        pendingScans: List<PendingScan>,
        uploadedResults: List<UploadedScanResult>
    ): List<FlushItemResult> {
        val resultsByIdempotencyKey = uploadedResults.associateBy { it.idempotency_key }

        return pendingScans.map { pendingScan ->
            val uploadedResult = resultsByIdempotencyKey[pendingScan.idempotencyKey]

            if (uploadedResult == null) {
                FlushItemResult(
                    idempotencyKey = pendingScan.idempotencyKey,
                    ticketCode = pendingScan.ticketCode,
                    outcome = FlushItemOutcome.RETRYABLE_FAILURE,
                    message = "No response row returned for queued scan."
                )
            } else {
                FlushItemResult(
                    idempotencyKey = pendingScan.idempotencyKey,
                    ticketCode = pendingScan.ticketCode,
                    outcome =
                        when (uploadedResult.status.lowercase()) {
                            "success" -> FlushItemOutcome.SUCCESS
                            "duplicate" -> FlushItemOutcome.DUPLICATE
                            "error" -> FlushItemOutcome.TERMINAL_ERROR
                            else -> FlushItemOutcome.TERMINAL_ERROR
                        },
                    message = uploadedResult.message,
                    // Additive only: status remains the primary behavior key.
                    reasonCode = normalizeReasonCode(uploadedResult)
                )
            }
        }
    }

    private fun normalizeReasonCode(result: UploadedScanResult): String? {
        val reasonCode = result.reason_code?.trim()?.lowercase()?.takeIf { it.isNotBlank() } ?: return null

        return when {
            result.status.equals("duplicate", ignoreCase = true) &&
                reasonCode in setOf("replay_duplicate", "business_duplicate") -> reasonCode

            result.status.equals("error", ignoreCase = true) &&
                reasonCode in setOf("payment_invalid", "business_duplicate") -> reasonCode

            else -> null
        }
    }
}
