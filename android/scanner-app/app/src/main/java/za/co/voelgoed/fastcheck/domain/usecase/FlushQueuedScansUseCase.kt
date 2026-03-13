package za.co.voelgoed.fastcheck.domain.usecase

import za.co.voelgoed.fastcheck.domain.model.FlushReport

interface FlushQueuedScansUseCase {
    suspend fun run(maxBatchSize: Int = 50): FlushReport
}
