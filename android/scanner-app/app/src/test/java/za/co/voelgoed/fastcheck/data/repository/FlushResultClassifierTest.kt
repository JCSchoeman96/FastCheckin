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
    fun classifiesCurrentPhoenixMessageShapedResults() {
        val outcomes =
            classifier.classify(
                pendingScans =
                    listOf(
                        samplePendingScan("idem-1", "VG-1"),
                        samplePendingScan("idem-2", "VG-2"),
                        samplePendingScan("idem-3", "VG-3"),
                        samplePendingScan("idem-4", "VG-4")
                    ),
                uploadedResults =
                    listOf(
                        UploadedScanResult("idem-1", "success", "Check-in successful"),
                        UploadedScanResult("idem-2", "duplicate", "Already checked in", "replay_duplicate"),
                        UploadedScanResult("idem-3", "error", "Ticket not found")
                    )
            )

        assertThat(outcomes.map { it.outcome })
            .containsExactly(
                FlushItemOutcome.SUCCESS,
                FlushItemOutcome.DUPLICATE,
                FlushItemOutcome.TERMINAL_ERROR,
                FlushItemOutcome.RETRYABLE_FAILURE
            )
            .inOrder()
        assertThat(outcomes[1].reasonCode).isEqualTo("replay_duplicate")
    }

    @Test
    fun ignoresReasonCodesThatDoNotMatchTheStatusShape() {
        val outcome =
            classifier.classify(
                pendingScans = listOf(samplePendingScan("idem-1", "VG-1")),
                uploadedResults =
                    listOf(
                        UploadedScanResult(
                            idempotency_key = "idem-1",
                            status = "duplicate",
                            message = "Already checked in",
                            reason_code = "payment_invalid"
                        )
                    )
            ).single()

        assertThat(outcome.outcome).isEqualTo(FlushItemOutcome.DUPLICATE)
        assertThat(outcome.reasonCode).isNull()
    }

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
