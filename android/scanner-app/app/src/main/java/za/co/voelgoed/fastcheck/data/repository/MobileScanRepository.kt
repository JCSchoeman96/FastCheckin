package za.co.voelgoed.fastcheck.data.repository

import kotlinx.coroutines.flow.Flow
import za.co.voelgoed.fastcheck.domain.model.FlushReport
import za.co.voelgoed.fastcheck.domain.model.PendingScan
import za.co.voelgoed.fastcheck.domain.model.QueueCreationResult
import za.co.voelgoed.fastcheck.domain.model.QuarantineSummary

/**
 * Runtime abstraction for local scan queueing and upload against the active
 * Phoenix mobile API contract.
 */
interface MobileScanRepository {
    suspend fun queueScan(scan: PendingScan): QueueCreationResult
    suspend fun flushQueuedScans(maxBatchSize: Int = 50): FlushReport
    suspend fun pendingQueueDepth(): Int
    suspend fun latestFlushReport(): FlushReport?

    fun observePendingQueueDepth(): Flow<Int>
    fun observeLatestFlushReport(): Flow<FlushReport?>

    suspend fun quarantineCount(): Int
    suspend fun latestQuarantineSummary(): QuarantineSummary?
    fun observeQuarantineCount(): Flow<Int>
    fun observeLatestQuarantineSummary(): Flow<QuarantineSummary?>
}
