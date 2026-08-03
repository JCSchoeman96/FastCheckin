package za.co.voelgoed.fastcheck.core.concurrency

import java.util.concurrent.ConcurrentHashMap
import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

interface EventOperationMutexRegistry {
    suspend fun <T> withFlushLock(eventId: Long, block: suspend () -> T): T

    suspend fun <T> withSyncLock(eventId: Long, block: suspend () -> T): T
}

@Singleton
class DefaultEventOperationMutexRegistry @Inject constructor() : EventOperationMutexRegistry {
    private val flushLocks = ConcurrentHashMap<Long, Mutex>()
    private val syncLocks = ConcurrentHashMap<Long, Mutex>()

    override suspend fun <T> withFlushLock(eventId: Long, block: suspend () -> T): T =
        flushLocks.mutexFor(eventId).withLock { block() }

    override suspend fun <T> withSyncLock(eventId: Long, block: suspend () -> T): T =
        syncLocks.mutexFor(eventId).withLock { block() }

    private fun ConcurrentHashMap<Long, Mutex>.mutexFor(eventId: Long): Mutex =
        computeIfAbsent(eventId) { Mutex() }
}
