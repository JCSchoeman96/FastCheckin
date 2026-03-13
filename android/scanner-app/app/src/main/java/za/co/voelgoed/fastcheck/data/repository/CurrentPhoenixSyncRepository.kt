package za.co.voelgoed.fastcheck.data.repository

import javax.inject.Inject
import javax.inject.Singleton
import za.co.voelgoed.fastcheck.data.local.ScannerDao
import za.co.voelgoed.fastcheck.data.mapper.toEntity
import za.co.voelgoed.fastcheck.data.mapper.toDomain
import za.co.voelgoed.fastcheck.data.mapper.toSyncMetadata
import za.co.voelgoed.fastcheck.data.remote.PhoenixMobileRemoteDataSource
import za.co.voelgoed.fastcheck.domain.model.AttendeeSyncStatus

@Singleton
class CurrentPhoenixSyncRepository @Inject constructor(
    private val remoteDataSource: PhoenixMobileRemoteDataSource,
    private val scannerDao: ScannerDao,
    private val sessionRepository: SessionRepository
) : SyncRepository {
    override suspend fun syncAttendees(): AttendeeSyncStatus? {
        val session = sessionRepository.currentSession() ?: return null
        val existing = scannerDao.loadSyncMetadata(session.eventId)
        val response = remoteDataSource.syncAttendees(existing?.lastServerTime)
        val payload = requireNotNull(response.data) { response.message ?: response.error ?: "Sync failed" }

        // Preserve the backend ticket_code as delivered until QR normalization is explicitly defined.
        scannerDao.upsertAttendees(payload.attendees.map { it.toEntity() })
        val metadata = payload.toSyncMetadata(session.eventId)
        scannerDao.upsertSyncMetadata(metadata)

        return metadata.toDomain()
    }

    override suspend fun currentSyncStatus(): AttendeeSyncStatus? =
        sessionRepository.currentSession()
            ?.let { scannerDao.loadSyncMetadata(it.eventId) }
            ?.toDomain()
}
