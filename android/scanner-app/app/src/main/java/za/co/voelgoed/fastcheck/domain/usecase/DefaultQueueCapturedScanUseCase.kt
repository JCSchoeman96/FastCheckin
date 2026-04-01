package za.co.voelgoed.fastcheck.domain.usecase

import java.time.Clock
import java.time.Instant
import java.util.UUID
import javax.inject.Inject
import za.co.voelgoed.fastcheck.core.ticket.TicketCodeNormalizer
import za.co.voelgoed.fastcheck.data.repository.MobileScanRepository
import za.co.voelgoed.fastcheck.data.repository.SessionAuthGateway
import za.co.voelgoed.fastcheck.domain.model.PendingScan
import za.co.voelgoed.fastcheck.domain.model.QueueCreationResult
import za.co.voelgoed.fastcheck.domain.model.ScanDirection

class DefaultQueueCapturedScanUseCase @Inject constructor(
    private val scanRepository: MobileScanRepository,
    private val sessionAuthGateway: SessionAuthGateway,
    private val clock: Clock
) : QueueCapturedScanUseCase {
    override suspend fun enqueue(
        ticketCode: String,
        direction: ScanDirection,
        operatorName: String,
        entranceName: String
    ): QueueCreationResult {
        val canonicalTicketCode =
            TicketCodeNormalizer.normalizeOrNull(ticketCode) ?: return QueueCreationResult.InvalidTicketCode

        val eventId = sessionAuthGateway.currentEventId() ?: return QueueCreationResult.MissingSessionContext
        val effectiveOperator = sessionAuthGateway.currentOperatorName() ?: operatorName.trim()
        val createdAt = clock.millis()
        val scan =
            PendingScan(
                eventId = eventId,
                ticketCode = canonicalTicketCode,
                idempotencyKey = UUID.randomUUID().toString(),
                createdAt = createdAt,
                scannedAt = Instant.ofEpochMilli(createdAt).toString(),
                direction = direction,
                entranceName = entranceName,
                operatorName = effectiveOperator
            )

        return scanRepository.queueScan(scan)
    }
}
