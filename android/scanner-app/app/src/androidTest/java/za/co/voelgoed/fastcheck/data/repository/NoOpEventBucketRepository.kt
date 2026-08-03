package za.co.voelgoed.fastcheck.data.repository

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flowOf
import za.co.voelgoed.fastcheck.domain.model.EventBucket

internal object NoOpEventBucketRepository : EventBucketRepository {
    override suspend fun activate(eventId: Long, eventName: String, eventShortname: String?) = Unit
    override suspend fun park(eventId: Long) = Unit
    override suspend fun markAuthRequired(eventId: Long) = Unit
    override suspend fun refreshSnapshots(eventId: Long) = Unit
    override suspend fun load(eventId: Long): EventBucket? = null
    override fun observeAllBuckets(): Flow<List<EventBucket>> = flowOf(emptyList())
}
