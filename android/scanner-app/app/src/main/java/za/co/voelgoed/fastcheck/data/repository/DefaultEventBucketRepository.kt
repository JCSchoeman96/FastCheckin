package za.co.voelgoed.fastcheck.data.repository

import androidx.room.withTransaction
import java.time.Clock
import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.combine
import za.co.voelgoed.fastcheck.core.database.FastCheckDatabase
import za.co.voelgoed.fastcheck.data.local.EventLocalBucketEntity
import za.co.voelgoed.fastcheck.data.local.EventLocalBucketState
import za.co.voelgoed.fastcheck.domain.model.EventBucket

@Singleton
class DefaultEventBucketRepository @Inject constructor(
    private val database: FastCheckDatabase,
    private val clock: Clock
) : EventBucketRepository {
    private val dao get() = database.scannerDao()

    override suspend fun activate(eventId: Long, eventName: String, eventShortname: String?) {
        require(eventId > 0)
        val now = clock.millis()
        database.withTransaction {
            dao.parkActiveEventLocalBuckets(now)
            val existing = dao.loadEventLocalBucket(eventId)
            dao.upsertEventLocalBucket(
                (existing ?: emptyBucket(eventId, now)).copy(
                    eventName = eventName,
                    eventShortname = eventShortname,
                    state = EventLocalBucketState.ACTIVE,
                    selectedAtEpochMillis = now,
                    lastActivatedAtEpochMillis = now,
                    updatedAtEpochMillis = now
                )
            )
            dao.refreshEventLocalBucketSnapshots(eventId, now)
        }
    }

    override suspend fun park(eventId: Long) = setState(eventId, EventLocalBucketState.PARKED)

    override suspend fun markAuthRequired(eventId: Long) =
        setState(eventId, EventLocalBucketState.AUTH_REQUIRED)

    override suspend fun refreshSnapshots(eventId: Long) {
        dao.refreshEventLocalBucketSnapshots(eventId, clock.millis())
    }

    override suspend fun load(eventId: Long): EventBucket? = dao.loadEventLocalBucket(eventId)?.toDomain()

    override fun observeAllBuckets(): Flow<List<EventBucket>> =
        combine(dao.observeAllEventLocalBuckets(), dao.observeAllSyncMetadata()) { rows, syncRows ->
            val syncByEvent = syncRows.associateBy { it.eventId }
            rows.map { it.toDomain(syncByEvent[it.eventId]?.lastAttemptedSyncAt) }
        }

    private suspend fun setState(eventId: Long, state: String) {
        require(eventId > 0)
        database.withTransaction {
            val now = clock.millis()
            val existing = dao.loadEventLocalBucket(eventId)
            dao.upsertEventLocalBucket(
                (existing ?: emptyBucket(eventId, now)).copy(
                    state = state,
                    updatedAtEpochMillis = now
                )
            )
            dao.refreshEventLocalBucketSnapshots(eventId, now)
        }
    }

    private fun emptyBucket(eventId: Long, now: Long) = EventLocalBucketEntity(
        eventId = eventId, state = EventLocalBucketState.PARKED,
        selectedAtEpochMillis = now, lastActivatedAtEpochMillis = now,
        closeRequestedAtEpochMillis = null, lastFlushAttemptAtEpochMillis = null,
        lastSuccessfulFlushAtEpochMillis = null, lastSuccessfulReconcileAtEpochMillis = null,
        pendingScanCountSnapshot = 0, activeOverlayCountSnapshot = 0,
        quarantinedScanCountSnapshot = 0, lastErrorCode = null, lastErrorMessage = null,
        updatedAtEpochMillis = now
    )
}

private fun EventLocalBucketEntity.toDomain(lastSyncAttempt: String? = null) = EventBucket(
    eventId, eventName, eventShortname, state, pendingScanCountSnapshot,
    awaitingReconciliationCountSnapshot, conflictCountSnapshot,
    quarantinedScanCountSnapshot, updatedAtEpochMillis, lastFlushAttemptAtEpochMillis, lastSyncAttempt
)
