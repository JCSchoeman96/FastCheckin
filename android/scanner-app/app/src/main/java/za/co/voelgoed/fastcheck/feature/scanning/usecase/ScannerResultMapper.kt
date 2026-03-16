package za.co.voelgoed.fastcheck.feature.scanning.usecase

import za.co.voelgoed.fastcheck.domain.model.QueueCreationResult
import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerCandidate
import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerResult

object ScannerResultMapper {
    fun fromQueueResult(
        candidate: ScannerCandidate,
        result: QueueCreationResult
    ): ScannerResult =
        when (result) {
            is QueueCreationResult.Enqueued ->
                ScannerResult.QueuedLocally(candidate)

            QueueCreationResult.ReplaySuppressed ->
                ScannerResult.ReplaySuppressed(candidate)

            QueueCreationResult.MissingSessionContext ->
                ScannerResult.MissingSessionContext(candidate)

            QueueCreationResult.InvalidTicketCode ->
                ScannerResult.InvalidTicketCode(candidate)
        }
}
