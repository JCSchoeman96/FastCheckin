package za.co.voelgoed.fastcheck.domain.usecase

import javax.inject.Inject
import za.co.voelgoed.fastcheck.data.repository.MobileScanRepository
import za.co.voelgoed.fastcheck.data.repository.FlushInvocationResult

class DefaultFlushQueuedScansUseCase @Inject constructor(
    private val scanRepository: MobileScanRepository
) : FlushQueuedScansUseCase {
    override suspend fun run(maxBatchSize: Int): FlushInvocationResult =
        scanRepository.flushQueuedScans(maxBatchSize = maxBatchSize)
}
