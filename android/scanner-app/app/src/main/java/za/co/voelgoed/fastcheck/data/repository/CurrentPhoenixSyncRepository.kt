package za.co.voelgoed.fastcheck.data.repository

import java.time.Clock
import java.time.Duration
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter
import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import retrofit2.HttpException
import za.co.voelgoed.fastcheck.core.ticket.TicketCodeNormalizer
import za.co.voelgoed.fastcheck.data.local.AttendeeEntity
import za.co.voelgoed.fastcheck.data.local.ScannerDao
import za.co.voelgoed.fastcheck.data.local.SyncMetadataEntity
import za.co.voelgoed.fastcheck.data.mapper.toDomain
import za.co.voelgoed.fastcheck.data.mapper.toEntity
import za.co.voelgoed.fastcheck.data.mapper.withIntegrityFailure
import za.co.voelgoed.fastcheck.data.mapper.withSyncFailure
import za.co.voelgoed.fastcheck.data.remote.MobileSyncPayload
import za.co.voelgoed.fastcheck.data.remote.PhoenixMobileRemoteDataSource
import za.co.voelgoed.fastcheck.core.sync.AttendeeSyncBootstrapStateHub
import za.co.voelgoed.fastcheck.domain.model.AttendeeSyncStatus
import za.co.voelgoed.fastcheck.domain.model.LocalAdmissionOverlayState

@Singleton
class CurrentPhoenixSyncRepository @Inject constructor(
    private val remoteDataSource: PhoenixMobileRemoteDataSource,
    private val scannerDao: ScannerDao,
    private val sessionRepository: SessionRepository,
    private val clock: Clock,
    private val bootstrapStateHub: AttendeeSyncBootstrapStateHub,
    private val overlayCatchUpPolicy: OverlayCatchUpPolicy = OverlayCatchUpPolicy()
) : SyncRepository {
    companion object {
        private const val SYNC_PAGE_LIMIT = 500
        private const val MAX_SYNC_PAGE_COUNT = 100
    }

    private val syncMutex = Mutex()

    override suspend fun syncAttendees(mode: AttendeeSyncMode): AttendeeSyncStatus? =
        syncMutex.withLock {
            syncAttendeesLocked(mode)
        }

    private suspend fun syncAttendeesLocked(mode: AttendeeSyncMode): AttendeeSyncStatus? {
        val session = sessionRepository.currentSession() ?: return null
        val eventId = session.eventId

        val previousSnapshot = scannerDao.loadSyncMetadata(eventId)

        if (mode == AttendeeSyncMode.FULL_RECONCILE) {
            scannerDao.clearEventAttendeeCacheForFullReconcile(eventId)
        }

        val sinceForFirstPage: String? =
            when (mode) {
                AttendeeSyncMode.FULL_RECONCILE -> null
                AttendeeSyncMode.INCREMENTAL -> previousSnapshot?.lastServerTime
            }

        val hasCompletedBootstrap =
            previousSnapshot != null &&
                listOfNotNull(
                    previousSnapshot.bootstrapCompletedAt,
                    previousSnapshot.lastSuccessfulSyncAt
                ).any { !it.isNullOrBlank() }

        if (!hasCompletedBootstrap) {
            bootstrapStateHub.notifyInitialBootstrapSyncActive(eventId)
        }

        return try {
            runPagedSync(
                eventId = eventId,
                sinceForFirstPage = sinceForFirstPage,
                previousBeforeLoop = previousSnapshot,
                mode = mode
            )
        } catch (pagination: SyncPaginationException) {
            val current = scannerDao.loadSyncMetadata(eventId)
            if (current != null) {
                scannerDao.upsertSyncMetadata(current.withIntegrityFailure(clock))
            }
            throw pagination
        } catch (http: HttpException) {
            val current = scannerDao.loadSyncMetadata(eventId)
            if (current != null) {
                scannerDao.upsertSyncMetadata(current.withSyncFailure(clock, "http_${http.code()}"))
            }
            if (http.code() == 429) {
                throw SyncRateLimitedException(
                    message =
                        "Sync is temporarily rate-limited. Please wait a moment before trying again.",
                    retryAfterMillis = parseRetryAfterMillis(http, clock)
                )
            } else {
                throw http
            }
        } catch (other: Throwable) {
            val current = scannerDao.loadSyncMetadata(eventId)
            if (current != null) {
                scannerDao.upsertSyncMetadata(current.withSyncFailure(clock, "sync_failed"))
            }
            throw other
        } finally {
            bootstrapStateHub.notifyInitialBootstrapSyncActive(null)
        }
    }

    private suspend fun runPagedSync(
        eventId: Long,
        sinceForFirstPage: String?,
        previousBeforeLoop: SyncMetadataEntity?,
        mode: AttendeeSyncMode
    ): AttendeeSyncStatus? {
        var cursor: String? = null
        var nextSince: String? = sinceForFirstPage
        val seenCursors = mutableSetOf<String>()
        var latestPayload: MobileSyncPayload? = null
        var totalFetched = 0
        var pagesFetched = 0

        do {
            if (pagesFetched >= MAX_SYNC_PAGE_COUNT) {
                throw SyncPaginationException(
                    message =
                        "Paged attendee sync exceeded max page count $MAX_SYNC_PAGE_COUNT " +
                            "with page size $SYNC_PAGE_LIMIT; sync was aborted to avoid an infinite loop " +
                            "before requesting page ${pagesFetched + 1}."
                )
            }

            val response =
                remoteDataSource.syncAttendees(
                    since = nextSince,
                    cursor = cursor,
                    limit = SYNC_PAGE_LIMIT
                )
            val payload =
                requireNotNull(response.data) { response.message ?: response.error ?: "Sync failed" }
            pagesFetched += 1

            latestPayload = payload
            val nextCursor = payload.next_cursor

            nextCursor?.let {
                if (!seenCursors.add(it)) {
                    throw SyncPaginationException(
                        message =
                            "Paged attendee sync received repeated pagination cursor '$it'; " +
                                "sync was aborted to avoid an infinite loop."
                    )
                }
            }

            val attendeesForPage = payload.toPersistableAttendees()

            if (attendeesForPage.isNotEmpty()) {
                // Progressive attendee writes keep sync heap bounded to a page at a time.
                // `sync_metadata` remains the last fully successful sync boundary, so callers
                // must tolerate attendee rows being ahead of metadata during or after a failed sync.
                scannerDao.upsertAttendees(attendeesForPage)
            }

            totalFetched += attendeesForPage.size
            cursor = nextCursor
            nextSince = null
        } while (cursor != null)

        val finalPayload = requireNotNull(latestPayload) { "Sync failed" }
        val metadata =
            buildSuccessMetadata(
                eventId = eventId,
                finalPayload = finalPayload,
                totalFetched = totalFetched,
                previousBeforeLoop = previousBeforeLoop,
                mode = mode
            )

        scannerDao.upsertSyncMetadata(metadata)
        resolveConfirmedAdmissionOverlays(eventId)

        return metadata.toDomain()
    }

    private fun buildSuccessMetadata(
        eventId: Long,
        finalPayload: MobileSyncPayload,
        totalFetched: Int,
        previousBeforeLoop: SyncMetadataEntity?,
        mode: AttendeeSyncMode
    ): SyncMetadataEntity {
        val nowIso = clock.instant().toString()
        val bootstrapCompletedAt: String? =
            when {
                !previousBeforeLoop?.bootstrapCompletedAt.isNullOrBlank() ->
                    previousBeforeLoop?.bootstrapCompletedAt

                !previousBeforeLoop?.lastSuccessfulSyncAt.isNullOrBlank() ->
                    previousBeforeLoop?.lastSuccessfulSyncAt

                else -> finalPayload.server_time
            }

        val incrementalCycles = (previousBeforeLoop?.incrementalCyclesSinceFullReconcile ?: 0) + 1

        val base =
            SyncMetadataEntity(
                eventId = eventId,
                lastServerTime = finalPayload.server_time,
                lastSuccessfulSyncAt = finalPayload.server_time,
                lastSyncType = finalPayload.sync_type,
                attendeeCount = totalFetched,
                bootstrapCompletedAt = bootstrapCompletedAt,
                lastAttemptedSyncAt = nowIso,
                consecutiveFailures = 0,
                lastErrorCode = null,
                lastErrorAt = null,
                lastFullReconcileAt = previousBeforeLoop?.lastFullReconcileAt ?: nowIso,
                incrementalCyclesSinceFullReconcile = incrementalCycles,
                consecutiveIntegrityFailures = 0,
                integrityFailuresInForegroundSession = previousBeforeLoop?.integrityFailuresInForegroundSession ?: 0
            )

        return when (mode) {
            AttendeeSyncMode.FULL_RECONCILE ->
                base.copy(
                    lastFullReconcileAt = nowIso,
                    incrementalCyclesSinceFullReconcile = 0,
                    consecutiveIntegrityFailures = 0,
                    integrityFailuresInForegroundSession = 0
                )

            AttendeeSyncMode.INCREMENTAL -> base
        }
    }

    override suspend fun currentSyncStatus(): AttendeeSyncStatus? =
        sessionRepository.currentSession()
            ?.let { scannerDao.loadSyncMetadata(it.eventId) }
            ?.toDomain()

    override fun observeLastSyncedStatus(): Flow<AttendeeSyncStatus?> =
        scannerDao.observeLatestSyncMetadata().map { it?.toDomain() }

    private suspend fun resolveConfirmedAdmissionOverlays(eventId: Long) {
        val overlays =
            scannerDao.loadOverlaysForEventByState(
                eventId = eventId,
                state = LocalAdmissionOverlayState.CONFIRMED_LOCAL_UNSYNCED.name
            )

        overlays.forEach { overlay ->
            val attendee =
                scannerDao.findAttendeeById(eventId, overlay.attendeeId)
                    ?: scannerDao.findAttendee(eventId, overlay.ticketCode)

            if (attendee != null && overlayCatchUpPolicy.hasSyncedBaseCaughtUp(attendee, overlay)) {
                scannerDao.deleteLocalAdmissionOverlayById(overlay.id)
            }
        }
    }
}

class SyncRateLimitedException(
    override val message: String,
    val retryAfterMillis: Long?
) : RuntimeException(message)

class SyncPaginationException(
    override val message: String
) : RuntimeException(message)

private fun MobileSyncPayload.toPersistableAttendees(): List<AttendeeEntity> =
    attendees.map { attendee ->
        val canonicalTicketCode =
            requireNotNull(TicketCodeNormalizer.normalizeOrNull(attendee.ticket_code)) {
                "Sync payload attendee ${attendee.id} had an invalid ticket_code."
            }

        attendee.toEntity().copy(ticketCode = canonicalTicketCode)
    }

private fun parseRetryAfterMillis(exception: HttpException, clock: Clock): Long? {
    val headerValue = exception.response()?.headers()?.get("Retry-After")?.trim()
    if (headerValue.isNullOrBlank()) return null

    headerValue.toLongOrNull()?.let { seconds ->
        if (seconds <= 0) return null
        return Duration.ofSeconds(seconds).toMillis()
    }

    return try {
        val retryTime = ZonedDateTime.parse(headerValue, DateTimeFormatter.RFC_1123_DATE_TIME).toInstant()
        val diff = Duration.between(clock.instant(), retryTime).toMillis()
        if (diff <= 0) null else diff
    } catch (_: Exception) {
        null
    }
}
