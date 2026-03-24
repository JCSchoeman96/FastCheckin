package za.co.voelgoed.fastcheck.data.repository

import com.google.common.truth.Truth.assertThat
import org.junit.Test
import za.co.voelgoed.fastcheck.data.remote.UploadedScanResult
import za.co.voelgoed.fastcheck.domain.model.FlushItemOutcome
import za.co.voelgoed.fastcheck.domain.model.PendingScan
import za.co.voelgoed.fastcheck.domain.model.ScanDirection

class FlushResultClassifierTest {
    private val classifier = FlushResultClassifier()

    @Test
    fun duplicateWithReplayDuplicatePreservesFinalReplayRefinement() {
        val outcome =
            classifySingle(
                UploadedScanResult(
                    idempotency_key = "idem-1",
                    status = "duplicate",
                    message = "Already checked in",
                    reason_code = "replay_duplicate"
                )
            )

        assertThat(outcome.outcome).isEqualTo(FlushItemOutcome.DUPLICATE)
        assertThat(outcome.reasonCode).isEqualTo("replay_duplicate")
    }

    @Test
    fun duplicateWithoutReplayDuplicateDoesNotClaimFinalReplayRefinement() {
        val outcome =
            classifySingle(
                UploadedScanResult(
                    idempotency_key = "idem-1",
                    status = "duplicate",
                    message = "Already checked in"
                )
            )

        assertThat(outcome.outcome).isEqualTo(FlushItemOutcome.DUPLICATE)
        assertThat(outcome.reasonCode).isNull()
    }

    @Test
    fun errorWithBusinessDuplicatePreservesSecondaryReason() {
        val outcome =
            classifySingle(
                UploadedScanResult(
                    idempotency_key = "idem-1",
                    status = "error",
                    message = "Already processed",
                    reason_code = "business_duplicate"
                )
            )

        assertThat(outcome.outcome).isEqualTo(FlushItemOutcome.TERMINAL_ERROR)
        assertThat(outcome.reasonCode).isEqualTo("business_duplicate")
    }

    @Test
    fun errorWithPaymentInvalidPreservesSecondaryReason() {
        val outcome =
            classifySingle(
                UploadedScanResult(
                    idempotency_key = "idem-1",
                    status = "error",
                    message = "Payment invalid",
                    reason_code = "payment_invalid"
                )
            )

        assertThat(outcome.outcome).isEqualTo(FlushItemOutcome.TERMINAL_ERROR)
        assertThat(outcome.reasonCode).isEqualTo("payment_invalid")
    }

    @Test
    fun errorWithUnknownReasonCodeStaysWithinBroadSemantics() {
        val outcome =
            classifySingle(
                UploadedScanResult(
                    idempotency_key = "idem-1",
                    status = "error",
                    message = "Unknown failure",
                    reason_code = "something_new"
                )
            )

        assertThat(outcome.outcome).isEqualTo(FlushItemOutcome.TERMINAL_ERROR)
        assertThat(outcome.reasonCode).isNull()
    }

    @Test
    fun successWithUnexpectedReasonCodeDoesNotDistortSuccessSemantics() {
        val outcome =
            classifySingle(
                UploadedScanResult(
                    idempotency_key = "idem-1",
                    status = "success",
                    message = "Check-in successful",
                    reason_code = "payment_invalid"
                )
            )

        assertThat(outcome.outcome).isEqualTo(FlushItemOutcome.SUCCESS)
        assertThat(outcome.reasonCode).isNull()
    }

    @Test
    fun missingResultRowAfterHttp200RemainsRetryable() {
        val outcome =
            classifier.classify(
                pendingScans = listOf(samplePendingScan("idem-1", "VG-1")),
                uploadedResults = emptyList()
            ).single()

        assertThat(outcome.outcome).isEqualTo(FlushItemOutcome.RETRYABLE_FAILURE)
        assertThat(outcome.reasonCode).isNull()
    }

    @Test
    fun ignoresReasonCodesThatDoNotMatchTheStatusShape() {
        val outcome =
            classifySingle(
                UploadedScanResult(
                    idempotency_key = "idem-1",
                    status = "duplicate",
                    message = "Already checked in",
                    reason_code = "payment_invalid"
                )
            )

        assertThat(outcome.outcome).isEqualTo(FlushItemOutcome.DUPLICATE)
        assertThat(outcome.reasonCode).isNull()
    }

    private fun classifySingle(uploadedResult: UploadedScanResult) =
        classifier.classify(
            pendingScans = listOf(samplePendingScan(uploadedResult.idempotency_key, "VG-1")),
            uploadedResults = listOf(uploadedResult)
        ).single()

    private fun samplePendingScan(idempotencyKey: String, ticketCode: String): PendingScan =
        PendingScan(
            eventId = 5,
            ticketCode = ticketCode,
            idempotencyKey = idempotencyKey,
            createdAt = 1_773_487_800_000,
            scannedAt = "2026-03-13T08:30:00Z",
            direction = ScanDirection.IN,
            entranceName = "Manual Debug",
            operatorName = "Operator"
        )
}
