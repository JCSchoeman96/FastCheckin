package za.co.voelgoed.fastcheck.data.repository

import kotlinx.coroutines.flow.Flow
import za.co.voelgoed.fastcheck.domain.model.EventBucket

interface EventBucketRepository {
    suspend fun activate(eventId: Long, eventName: String, eventShortname: String?)
    suspend fun park(eventId: Long)
    suspend fun markAuthRequired(eventId: Long)
    suspend fun refreshSnapshots(eventId: Long)
    suspend fun load(eventId: Long): EventBucket?
    fun observeAllBuckets(): Flow<List<EventBucket>>
}
