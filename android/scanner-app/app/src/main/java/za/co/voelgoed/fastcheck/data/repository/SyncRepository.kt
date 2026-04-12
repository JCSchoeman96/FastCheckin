package za.co.voelgoed.fastcheck.data.repository

import kotlinx.coroutines.flow.Flow
import za.co.voelgoed.fastcheck.domain.model.AttendeeSyncStatus

interface SyncRepository {
    suspend fun syncAttendees(mode: AttendeeSyncMode = AttendeeSyncMode.INCREMENTAL): AttendeeSyncStatus?

    suspend fun currentSyncStatus(): AttendeeSyncStatus?

    /**
     * Durable local truth for the last successful attendee sync, independent of active session.
     */
    fun observeLastSyncedStatus(): Flow<AttendeeSyncStatus?>
}
