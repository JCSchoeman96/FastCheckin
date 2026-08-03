package za.co.voelgoed.fastcheck.di

import java.util.concurrent.ConcurrentHashMap
import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import za.co.voelgoed.fastcheck.core.session.AuthenticatedEventIdentity
import za.co.voelgoed.fastcheck.data.repository.FlushInvocationResult
import za.co.voelgoed.fastcheck.data.repository.MobileScanRepository
import za.co.voelgoed.fastcheck.domain.model.FlushExecutionStatus
import za.co.voelgoed.fastcheck.domain.model.FlushReport
import za.co.voelgoed.fastcheck.domain.model.PendingScan
import za.co.voelgoed.fastcheck.domain.model.QueueCreationResult
import za.co.voelgoed.fastcheck.domain.model.QuarantineSummary

@Singleton
class TestMobileScanRepository @Inject constructor() : MobileScanRepository {
    private val pendingDepths = ConcurrentHashMap<Long, MutableStateFlow<Int>>()

    override suspend fun queueScan(scan: PendingScan): QueueCreationResult =
        QueueCreationResult.Enqueued(scan)

    override suspend fun flushQueuedScans(maxBatchSize: Int): FlushInvocationResult =
        FlushInvocationResult.Attempted(
            AuthenticatedEventIdentity(5L, 1L),
            FlushReport(executionStatus = FlushExecutionStatus.COMPLETED, uploadedCount = 0)
        )

    override suspend fun pendingQueueDepth(eventId: Long): Int = depthFlow(eventId).value

    override suspend fun latestFlushReport(eventId: Long): FlushReport? = null

    override fun observePendingQueueDepth(eventId: Long): Flow<Int> = depthFlow(eventId)

    override fun observeLatestFlushReport(eventId: Long): Flow<FlushReport?> = MutableStateFlow(null)

    override suspend fun quarantineCount(eventId: Long): Int = 0

    override suspend fun latestQuarantineSummary(eventId: Long): QuarantineSummary? = null

    override fun observeQuarantineCount(eventId: Long): Flow<Int> = MutableStateFlow(0)

    override fun observeLatestQuarantineSummary(eventId: Long): Flow<QuarantineSummary?> =
        MutableStateFlow(null)

    fun setPendingQueueDepth(eventId: Long, depth: Int) {
        depthFlow(eventId).value = depth
    }

    fun reset() {
        pendingDepths.values.forEach { it.value = 0 }
        pendingDepths.clear()
    }

    private fun depthFlow(eventId: Long): MutableStateFlow<Int> =
        pendingDepths.getOrPut(eventId) { MutableStateFlow(0) }
}
