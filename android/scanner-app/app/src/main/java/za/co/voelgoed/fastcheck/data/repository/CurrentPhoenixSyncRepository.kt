package za.co.voelgoed.fastcheck.data.repository

import java.time.Clock
import java.time.Duration
import java.time.Instant
import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map
import retrofit2.HttpException
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
    private val sessionRepository: SessionRepository,
    private val clock: Clock
) : SyncRepository {
    override suspend fun syncAttendees(): AttendeeSyncStatus? {
        val session = sessionRepository.currentSession() ?: return null
        val existing = scannerDao.loadSyncMetadata(session.eventId)

        try {
            val response = remoteDataSource.syncAttendees(existing?.lastServerTime)
            val payload =
                requireNotNull(response.data) { response.message ?: response.error ?: "Sync failed" }

            // Preserve the backend ticket_code as delivered until QR normalization is explicitly defined.
            val metadata = payload.toSyncMetadata(session.eventId)
            scannerDao.upsertAttendeesAndSyncMetadata(
                attendees = payload.attendees.map { it.toEntity() },
                metadata = metadata
            )

            return metadata.toDomain()
        } catch (http: HttpException) {
            if (http.code() == 429) {
                throw SyncRateLimitedException(
                    message =
                        "Sync is temporarily rate-limited. Please wait a moment before trying again.",
                    retryAfterMillis = parseRetryAfterMillis(http, clock)
                )
            } else {
                throw http
            }
        }
    }

    override suspend fun currentSyncStatus(): AttendeeSyncStatus? =
        sessionRepository.currentSession()
            ?.let { scannerDao.loadSyncMetadata(it.eventId) }
            ?.toDomain()

    override fun observeLastSyncedStatus(): Flow<AttendeeSyncStatus?> =
        scannerDao.observeLatestSyncMetadata().map { it?.toDomain() }
}

class SyncRateLimitedException(
    override val message: String,
    val retryAfterMillis: Long?
) : RuntimeException(message)

private fun parseRetryAfterMillis(exception: HttpException, clock: Clock): Long? {
    val headerValue = exception.response()?.headers()?.get("Retry-After") ?: return null

    // Retry-After can be either seconds or HTTP-date; support the common seconds form first.
    headerValue.toLongOrNull()?.let { seconds ->
        return Duration.ofSeconds(seconds).toMillis()
    }

    // Fallback: try HTTP-date parsing if needed in the future.
    return try {
        val retryTime = Instant.parse(headerValue)
        val now = Instant.ofEpochMilli(clock.millis())
        val diff = Duration.between(now, retryTime).toMillis()
        if (diff > 0) diff else null
    } catch (_: Exception) {
        null
    }
}
