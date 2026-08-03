package za.co.voelgoed.fastcheck.domain.usecase

import za.co.voelgoed.fastcheck.data.repository.FlushInvocationResult

interface FlushQueuedScansUseCase {
    suspend fun run(maxBatchSize: Int = 50): FlushInvocationResult
}
