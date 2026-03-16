package za.co.voelgoed.fastcheck.domain.usecase

import javax.inject.Inject
import za.co.voelgoed.fastcheck.data.repository.MobileScanRepository
import za.co.voelgoed.fastcheck.domain.model.FlushReport

class DefaultFlushQueuedScansUseCase @Inject constructor(
    private val scanRepository: MobileScanRepository
) : FlushQueuedScansUseCase {
    override suspend fun run(maxBatchSize: Int): FlushReport =
        scanRepository.flushQueuedScans(maxBatchSize = maxBatchSize)
}
