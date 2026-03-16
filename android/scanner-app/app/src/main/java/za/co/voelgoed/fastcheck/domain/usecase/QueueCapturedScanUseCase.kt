package za.co.voelgoed.fastcheck.domain.usecase

import za.co.voelgoed.fastcheck.domain.model.ScanDirection
import za.co.voelgoed.fastcheck.domain.model.QueueCreationResult

interface QueueCapturedScanUseCase {
    suspend fun enqueue(
        ticketCode: String,
        direction: ScanDirection,
        operatorName: String,
        entranceName: String
    ): QueueCreationResult
}
