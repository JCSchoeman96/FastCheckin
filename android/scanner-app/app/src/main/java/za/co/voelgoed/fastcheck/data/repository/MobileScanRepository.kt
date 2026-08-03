package za.co.voelgoed.fastcheck.data.repository

import kotlinx.coroutines.flow.Flow
import za.co.voelgoed.fastcheck.domain.model.FlushReport
import za.co.voelgoed.fastcheck.domain.model.PendingScan
import za.co.voelgoed.fastcheck.domain.model.QueueCreationResult
import za.co.voelgoed.fastcheck.domain.model.QuarantineSummary
import za.co.voelgoed.fastcheck.core.session.AuthenticatedEventIdentity

/**
 * Runtime abstraction for local scan queueing and upload against the active
 * Phoenix mobile API contract.
 */
interface MobileScanRepository {
    suspend fun queueScan(scan: PendingScan): QueueCreationResult
    suspend fun flushQueuedScans(maxBatchSize: Int = 50): FlushInvocationResult
    suspend fun pendingQueueDepth(eventId: Long): Int
    suspend fun latestFlushReport(eventId: Long): FlushReport?

    fun observePendingQueueDepth(eventId: Long): Flow<Int>
    fun observeLatestFlushReport(eventId: Long): Flow<FlushReport?>

    suspend fun quarantineCount(eventId: Long): Int
    suspend fun latestQuarantineSummary(eventId: Long): QuarantineSummary?
    fun observeQuarantineCount(eventId: Long): Flow<Int>
    fun observeLatestQuarantineSummary(eventId: Long): Flow<QuarantineSummary?>
}

sealed interface FlushInvocationResult {
    data object SkippedNoSession : FlushInvocationResult

    data class Attempted(
        val identity: AuthenticatedEventIdentity,
        val report: FlushReport
    ) : FlushInvocationResult
}
