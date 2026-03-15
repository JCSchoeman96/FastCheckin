package za.co.voelgoed.fastcheck.data.mapper

import com.google.common.truth.Truth.assertThat
import org.junit.Test
import za.co.voelgoed.fastcheck.domain.model.FlushExecutionStatus
import za.co.voelgoed.fastcheck.domain.model.FlushItemOutcome
import za.co.voelgoed.fastcheck.domain.model.FlushItemResult
import za.co.voelgoed.fastcheck.domain.model.FlushReport
import za.co.voelgoed.fastcheck.domain.model.PendingScan
import za.co.voelgoed.fastcheck.domain.model.ScanDirection

class QueuedScanMappersTest {
    @Test
    fun mapsPendingScanToEntityAndPhoenixPayload() {
        val scan =
            PendingScan(
                localId = 7,
                eventId = 10,
                ticketCode = "VG-777",
                idempotencyKey = "idem-777",
                createdAt = 1_773_400_000_000,
                scannedAt = "2026-03-12T10:15:00Z",
                direction = ScanDirection.OUT,
                entranceName = "Main Gate",
                operatorName = "Scanner 1"
            )

        val entity = scan.toEntity()
        val payload = scan.toPayload()

        assertThat(entity.id).isEqualTo(7)
        assertThat(entity.createdAt).isEqualTo(1_773_400_000_000)
        assertThat(entity.direction).isEqualTo("out")
        assertThat(payload.idempotency_key).isEqualTo("idem-777")
        assertThat(payload.direction).isEqualTo("in")
    }

    @Test
    fun mapsQueuedEntityBackToRuntimeInDirectionOnly() {
        val entity =
            PendingScan(
                localId = 2,
                eventId = 10,
                ticketCode = "VG-100",
                idempotencyKey = "idem-100",
                createdAt = 1_773_400_000_000,
                scannedAt = "2026-03-12T10:00:00Z",
                direction = ScanDirection.OUT,
                entranceName = "Front",
                operatorName = "Operator"
            ).toEntity()

        val domain = entity.toDomain()

        assertThat(domain.direction).isEqualTo(ScanDirection.IN)
    }

    @Test
    fun mapsLatestFlushSnapshotBackToDomain() {
        val report =
            FlushReport(
                executionStatus = FlushExecutionStatus.COMPLETED,
                itemOutcomes =
                    listOf(
                        FlushItemResult(
                            idempotencyKey = "idem-1",
                            ticketCode = "VG-1",
                            outcome = FlushItemOutcome.DUPLICATE,
                            message = "Already checked in"
                        )
                    ),
                uploadedCount = 1,
                retryableRemainingCount = 0,
                authExpired = false,
                backlogRemaining = false,
                summaryMessage = "Flush completed."
            )

        val snapshot = report.toSnapshotEntity("2026-03-12T10:16:00Z")
        val outcomes = report.toOutcomeEntities("2026-03-12T10:16:00Z")
        val restored = toFlushReport(snapshot, outcomes)

        assertThat(restored.executionStatus).isEqualTo(FlushExecutionStatus.COMPLETED)
        assertThat(restored.itemOutcomes.single().outcome).isEqualTo(FlushItemOutcome.DUPLICATE)
    }
}
