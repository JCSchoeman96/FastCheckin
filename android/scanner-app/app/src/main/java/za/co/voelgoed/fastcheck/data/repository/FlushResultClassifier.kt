package za.co.voelgoed.fastcheck.data.repository

import javax.inject.Inject
import javax.inject.Singleton
import za.co.voelgoed.fastcheck.data.remote.UploadedScanResult
import za.co.voelgoed.fastcheck.domain.model.FlushItemOutcome
import za.co.voelgoed.fastcheck.domain.model.FlushItemResult
import za.co.voelgoed.fastcheck.domain.model.PendingScan

/**
 * Isolates the current Phoenix mobile API's message-shaped scan result
 * semantics. Replace this classifier if the backend later publishes stable
 * reason codes.
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
                            else -> FlushItemOutcome.TERMINAL_ERROR
                        },
                    message = uploadedResult.message
                )
            }
        }
    }
}
