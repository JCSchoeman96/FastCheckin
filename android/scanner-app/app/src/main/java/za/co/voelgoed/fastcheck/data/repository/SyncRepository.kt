package za.co.voelgoed.fastcheck.data.repository

import kotlinx.coroutines.flow.Flow
import za.co.voelgoed.fastcheck.domain.model.AttendeeSyncStatus
import za.co.voelgoed.fastcheck.core.session.AuthenticatedEventIdentity

interface SyncRepository {
    suspend fun syncAttendees(mode: AttendeeSyncMode = AttendeeSyncMode.INCREMENTAL): AttendeeSyncStatus?

    suspend fun currentSyncStatus(): AttendeeSyncStatus?

    fun observeLastSyncedStatus(identity: AuthenticatedEventIdentity): Flow<AttendeeSyncStatus?>
}
