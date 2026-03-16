package za.co.voelgoed.fastcheck.data.repository

import za.co.voelgoed.fastcheck.domain.model.AttendeeSyncStatus

interface SyncRepository {
    suspend fun syncAttendees(): AttendeeSyncStatus?
    suspend fun currentSyncStatus(): AttendeeSyncStatus?
}
