package za.co.voelgoed.fastcheck.data.repository

import java.time.Clock
import java.time.Duration
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter
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
    private val syncPageLimit = 500

    override suspend fun syncAttendees(): AttendeeSyncStatus? {
        val session = sessionRepository.currentSession() ?: return null
        val existing = scannerDao.loadSyncMetadata(session.eventId)

        try {
            var cursor: String? = null
            var latestPayload: za.co.voelgoed.fastcheck.data.remote.MobileSyncPayload? = null
            var totalFetched = 0

            do {
                val response =
                    remoteDataSource.syncAttendees(
                        since = existing?.lastServerTime,
                        cursor = cursor,
                        limit = syncPageLimit
                    )
                val payload =
                    requireNotNull(response.data) { response.message ?: response.error ?: "Sync failed" }

                latestPayload = payload
                totalFetched += payload.attendees.size

                // Preserve the backend ticket_code as delivered until QR normalization is explicitly defined.
                if (payload.attendees.isNotEmpty()) {
                    scannerDao.upsertAttendees(payload.attendees.map { it.toEntity() })
                }

                cursor = payload.next_cursor
            } while (cursor != null)

            val finalPayload = requireNotNull(latestPayload) { "Sync failed" }
            val metadata = finalPayload.toSyncMetadata(session.eventId).copy(attendeeCount = totalFetched)
            scannerDao.upsertSyncMetadata(metadata)

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
    val headerValue = exception.response()?.headers()?.get("Retry-After")?.trim()
    if (headerValue.isNullOrBlank()) return null

    // Retry-After can be either seconds or an RFC 1123 HTTP-date; support the seconds form first.
    headerValue.toLongOrNull()?.let { seconds ->
        if (seconds <= 0) return null
        return Duration.ofSeconds(seconds).toMillis()
    }

    // Parse the RFC 1123 HTTP-date form and convert it to retry delay milliseconds.
    return try {
        val retryTime = ZonedDateTime.parse(headerValue, DateTimeFormatter.RFC_1123_DATE_TIME).toInstant()
        val diff = Duration.between(clock.instant(), retryTime).toMillis()
        if (diff <= 0) null else diff
    } catch (_: Exception) {
        null
    }
}
