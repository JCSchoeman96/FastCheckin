package za.co.voelgoed.fastcheck.domain.usecase

import com.google.common.truth.Truth.assertThat
import java.time.Clock
import java.time.Instant
import java.time.ZoneOffset
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.runTest
import org.junit.Test
import za.co.voelgoed.fastcheck.data.repository.MobileScanRepository
import za.co.voelgoed.fastcheck.data.repository.SessionAuthGateway
import za.co.voelgoed.fastcheck.domain.model.FlushReport
import za.co.voelgoed.fastcheck.domain.model.PendingScan
import za.co.voelgoed.fastcheck.domain.model.QueueCreationResult
import za.co.voelgoed.fastcheck.domain.model.ScanDirection

class DefaultQueueCapturedScanUseCaseTest {
    private val clock = Clock.fixed(Instant.parse("2026-03-13T08:30:00Z"), ZoneOffset.UTC)

    @Test
    fun preservesNonBlankTicketCodeExactlyWhenQueueing() = runTest {
        val repository = RecordingMobileScanRepository()
        val useCase =
            DefaultQueueCapturedScanUseCase(
                scanRepository = repository,
                sessionAuthGateway = FakeSessionAuthGateway(eventId = 5, operatorName = "Stored Operator"),
                clock = clock
            )

        val result =
            useCase.enqueue(
                ticketCode = "  VG-101  ",
                direction = ScanDirection.IN,
                operatorName = "UI Operator",
                entranceName = "Manual Debug"
            )

        assertThat(result).isInstanceOf(QueueCreationResult.Enqueued::class.java)
        assertThat(repository.lastQueuedScan?.ticketCode).isEqualTo("  VG-101  ")
        assertThat(repository.lastQueuedScan?.createdAt).isEqualTo(clock.millis())
        assertThat(repository.lastQueuedScan?.scannedAt).isEqualTo("2026-03-13T08:30:00Z")
        assertThat(repository.lastQueuedScan?.operatorName).isEqualTo("Stored Operator")
    }

    @Test
    fun rejectsBlankInputWithoutCreatingQueueRow() = runTest {
        val repository = RecordingMobileScanRepository()
        val useCase =
            DefaultQueueCapturedScanUseCase(
                scanRepository = repository,
                sessionAuthGateway = FakeSessionAuthGateway(eventId = 5, operatorName = null),
                clock = clock
            )

        val result =
            useCase.enqueue(
                ticketCode = "   ",
                direction = ScanDirection.IN,
                operatorName = "UI Operator",
                entranceName = "Manual Debug"
            )

        assertThat(result).isEqualTo(QueueCreationResult.InvalidTicketCode)
        assertThat(repository.lastQueuedScan).isNull()
    }

    @Test
    fun failsCleanlyWhenSessionContextIsMissing() = runTest {
        val repository = RecordingMobileScanRepository()
        val useCase =
            DefaultQueueCapturedScanUseCase(
                scanRepository = repository,
                sessionAuthGateway = FakeSessionAuthGateway(eventId = null, operatorName = null),
                clock = clock
            )

        val result =
            useCase.enqueue(
                ticketCode = "VG-500",
                direction = ScanDirection.IN,
                operatorName = "UI Operator",
                entranceName = "Manual Debug"
            )

        assertThat(result).isEqualTo(QueueCreationResult.MissingSessionContext)
        assertThat(repository.lastQueuedScan).isNull()
    }

    @Test
    fun generatesUniqueIdempotencyKeysForDistinctQueueRequests() = runTest {
        val repository = RecordingMobileScanRepository()
        val useCase =
            DefaultQueueCapturedScanUseCase(
                scanRepository = repository,
                sessionAuthGateway = FakeSessionAuthGateway(eventId = 5, operatorName = null),
                clock = clock
            )

        useCase.enqueue("VG-1", ScanDirection.IN, "UI Operator", "Manual Debug")
        val firstIdempotencyKey = repository.lastQueuedScan?.idempotencyKey
        useCase.enqueue("VG-2", ScanDirection.IN, "UI Operator", "Manual Debug")
        val secondIdempotencyKey = repository.lastQueuedScan?.idempotencyKey

        assertThat(firstIdempotencyKey).isNotNull()
        assertThat(secondIdempotencyKey).isNotNull()
        assertThat(firstIdempotencyKey).isNotEqualTo(secondIdempotencyKey)
    }

    private class RecordingMobileScanRepository : MobileScanRepository {
        var lastQueuedScan: PendingScan? = null
        private val depthFlow = MutableStateFlow(0)
        private val latestFlushFlow = MutableStateFlow<FlushReport?>(null)

        override suspend fun queueScan(scan: PendingScan): QueueCreationResult {
            lastQueuedScan = scan
            return QueueCreationResult.Enqueued(scan)
        }

        override suspend fun flushQueuedScans(maxBatchSize: Int): FlushReport {
            error("Not used in this test")
        }

        override suspend fun pendingQueueDepth(): Int = 0

        override suspend fun latestFlushReport(): FlushReport? = null

        override fun observePendingQueueDepth(): Flow<Int> = depthFlow

        override fun observeLatestFlushReport(): Flow<FlushReport?> = latestFlushFlow
    }

    private data class FakeSessionAuthGateway(
        val eventId: Long?,
        val operatorName: String?
    ) : SessionAuthGateway {
        override suspend fun currentEventId(): Long? = eventId

        override suspend fun currentOperatorName(): String? = operatorName
    }
}
