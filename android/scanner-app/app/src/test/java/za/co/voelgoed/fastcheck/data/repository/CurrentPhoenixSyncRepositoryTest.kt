package za.co.voelgoed.fastcheck.data.repository

import android.content.Context
import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import com.google.common.truth.Truth.assertThat
import java.time.Clock
import java.time.Instant
import java.time.ZoneOffset
import kotlinx.coroutines.test.runTest
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.Protocol
import okhttp3.Request
import okhttp3.ResponseBody
import org.junit.After
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import retrofit2.HttpException
import retrofit2.Response
import za.co.voelgoed.fastcheck.core.database.FastCheckDatabase
import za.co.voelgoed.fastcheck.core.network.PhoenixMobileApi
import za.co.voelgoed.fastcheck.data.local.SyncMetadataEntity
import za.co.voelgoed.fastcheck.data.mapper.toEntity
import za.co.voelgoed.fastcheck.data.remote.AttendeeDto
import za.co.voelgoed.fastcheck.data.remote.MobileLoginPayload
import za.co.voelgoed.fastcheck.data.remote.MobileLoginRequest
import za.co.voelgoed.fastcheck.data.remote.MobileLoginResponse
import za.co.voelgoed.fastcheck.data.remote.MobileSyncPayload
import za.co.voelgoed.fastcheck.data.remote.MobileSyncResponse
import za.co.voelgoed.fastcheck.data.remote.PhoenixMobileRemoteDataSource
import za.co.voelgoed.fastcheck.data.remote.UploadScansRequest
import za.co.voelgoed.fastcheck.data.remote.UploadScansResponse
import za.co.voelgoed.fastcheck.domain.model.ScannerSession

@RunWith(RobolectricTestRunner::class)
class CurrentPhoenixSyncRepositoryTest {
    private lateinit var database: FastCheckDatabase
    private lateinit var api: FakePhoenixMobileApi
    private lateinit var repository: CurrentPhoenixSyncRepository

    @Before
    fun setUp() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        database =
            Room.inMemoryDatabaseBuilder(context, FastCheckDatabase::class.java)
                .allowMainThreadQueries()
                .build()
        api = FakePhoenixMobileApi()
        repository = buildRepository(sessionRepository = fixedSessionRepository())
    }

    @After
    fun tearDown() {
        database.close()
    }

    @Test
    fun initialSyncUsesNullWatermarkAndPersistsAttendeeAndMetadata() = runTest {
        api.syncResponse =
            MobileSyncResponse(
                data =
                    MobileSyncPayload(
                        server_time = "2026-03-13T08:10:00Z",
                        attendees =
                            listOf(
                                AttendeeDto(
                                    id = 1,
                                    event_id = 5,
                                    ticket_code = "VG-100",
                                    first_name = "Jane",
                                    last_name = "Doe",
                                    email = "jane@example.com",
                                    ticket_type = "VIP",
                                    allowed_checkins = 1,
                                    checkins_remaining = 1,
                                    payment_status = "completed",
                                    is_currently_inside = false,
                                    checked_in_at = null,
                                    checked_out_at = null,
                                    updated_at = "2026-03-13T08:09:00Z"
                                )
                            ),
                        count = 1,
                        sync_type = "full"
                    ),
                error = null,
                message = null
            )

        val status = repository.syncAttendees()
        val attendee = database.scannerDao().findAttendee(5, "VG-100")
        val metadata = database.scannerDao().loadSyncMetadata(5)

        assertThat(api.lastSince).isNull()
        assertThat(attendee?.ticketCode).isEqualTo("VG-100")
        assertThat(metadata?.lastServerTime).isEqualTo("2026-03-13T08:10:00Z")
        assertThat(metadata?.lastSyncType).isEqualTo("full")
        assertThat(status?.attendeeCount).isEqualTo(1)
        assertThat(status?.syncType).isEqualTo("full")
    }

    @Test
    fun incrementalSyncUsesStoredLastServerTimeWatermark() = runTest {
        database.scannerDao().upsertSyncMetadata(
            SyncMetadataEntity(
                eventId = 5,
                lastServerTime = "2026-03-13T08:00:00Z",
                lastSuccessfulSyncAt = "2026-03-13T08:00:00Z",
                lastSyncType = "full",
                attendeeCount = 5
            )
        )

        api.syncResponse =
            MobileSyncResponse(
                data =
                    MobileSyncPayload(
                        server_time = "2026-03-13T08:20:00Z",
                        attendees = emptyList(),
                        count = 5,
                        sync_type = "incremental"
                    ),
                error = null,
                message = null
            )

        val status = repository.syncAttendees()

        assertThat(api.lastSince).isEqualTo("2026-03-13T08:00:00Z")
        assertThat(status?.lastSuccessfulSyncAt).isEqualTo("2026-03-13T08:20:00Z")
        assertThat(database.scannerDao().loadSyncMetadata(5)?.lastSyncType).isEqualTo("incremental")
    }

    @Test
    fun syncAttendeesWithoutSessionReturnsNullAndDoesNotWrite() = runTest {
        repository = buildRepository(sessionRepository = noSessionRepository())

        val status = repository.syncAttendees()

        assertThat(status).isNull()
        assertThat(api.lastSince).isNull()
        assertThat(database.scannerDao().findAttendee(5, "VG-100")).isNull()
        assertThat(database.scannerDao().loadSyncMetadata(5)).isNull()
    }

    @Test
    fun successfulSyncPersistsAttendeeRowAndSyncMetadataRow() = runTest {
        api.syncResponse =
            MobileSyncResponse(
                data =
                    MobileSyncPayload(
                        server_time = "2026-03-13T08:30:00Z",
                        attendees =
                            listOf(
                                AttendeeDto(
                                    id = 12,
                                    event_id = 5,
                                    ticket_code = "VG-ROW-12",
                                    first_name = "Sam",
                                    last_name = "Example",
                                    email = "sam@example.com",
                                    ticket_type = "General",
                                    allowed_checkins = 2,
                                    checkins_remaining = 2,
                                    payment_status = "completed",
                                    is_currently_inside = false,
                                    checked_in_at = null,
                                    checked_out_at = null,
                                    updated_at = "2026-03-13T08:29:00Z"
                                )
                            ),
                        count = 1,
                        sync_type = "full"
                    ),
                error = null,
                message = null
            )

        repository.syncAttendees()

        val attendee = database.scannerDao().findAttendee(5, "VG-ROW-12")
        val metadata = database.scannerDao().loadSyncMetadata(5)

        assertThat(attendee).isNotNull()
        assertThat(attendee?.id).isEqualTo(12)
        assertThat(metadata).isNotNull()
        assertThat(metadata?.eventId).isEqualTo(5)
        assertThat(metadata?.attendeeCount).isEqualTo(1)
    }

    @Test
    fun mapsHttp429ToSyncRateLimitedExceptionWithoutRetryAfterHeader() = runTest {
        repository = buildRateLimitedRepository(retryAfterHeader = null)

        try {
            repository.syncAttendees()
            error("Expected SyncRateLimitedException")
        } catch (e: Exception) {
            assertThat(e).isInstanceOf(SyncRateLimitedException::class.java)
            assertThat((e as SyncRateLimitedException).retryAfterMillis).isNull()
        }
    }

    @Test
    fun mapsHttp429ToSyncRateLimitedExceptionWithTrimmedPositiveNumericRetryAfterHeader() = runTest {
        repository = buildRateLimitedRepository(retryAfterHeader = " 120 ")

        try {
            repository.syncAttendees()
            error("Expected SyncRateLimitedException")
        } catch (e: Exception) {
            assertThat(e).isInstanceOf(SyncRateLimitedException::class.java)
            assertThat((e as SyncRateLimitedException).retryAfterMillis).isEqualTo(120_000L)
        }
    }

    @Test
    fun mapsHttp429ToSyncRateLimitedExceptionWithBlankRetryAfterAsNull() = runTest {
        repository = buildRateLimitedRepository(retryAfterHeader = "   ")

        try {
            repository.syncAttendees()
            error("Expected SyncRateLimitedException")
        } catch (e: Exception) {
            assertThat(e).isInstanceOf(SyncRateLimitedException::class.java)
            assertThat((e as SyncRateLimitedException).retryAfterMillis).isNull()
        }
    }

    @Test
    fun mapsHttp429ToSyncRateLimitedExceptionWithNonPositiveAndMalformedRetryAfterAsNull() = runTest {
        val invalidHeaders = listOf("", "   ", "0", "-5", "abc")

        invalidHeaders.forEach { header ->
            repository = buildRateLimitedRepository(retryAfterHeader = header)

            try {
                repository.syncAttendees()
                error("Expected SyncRateLimitedException for Retry-After header: $header")
            } catch (e: Exception) {
                assertThat(e).isInstanceOf(SyncRateLimitedException::class.java)
                assertThat((e as SyncRateLimitedException).retryAfterMillis).isNull()
            }
        }
    }

    @Test
    fun mapsHttp429ToSyncRateLimitedExceptionWithFutureRetryAfterHttpDate() = runTest {
        repository = buildRateLimitedRepository(retryAfterHeader = "Fri, 13 Mar 2026 08:02:00 GMT")

        try {
            repository.syncAttendees()
            error("Expected SyncRateLimitedException")
        } catch (e: Exception) {
            assertThat(e).isInstanceOf(SyncRateLimitedException::class.java)
            assertThat((e as SyncRateLimitedException).retryAfterMillis).isNotNull()
            assertThat(e.retryAfterMillis!!).isGreaterThan(0L)
        }
    }

    @Test
    fun mapsHttp429ToSyncRateLimitedExceptionWithPastRetryAfterHttpDateAsNull() = runTest {
        repository = buildRateLimitedRepository(retryAfterHeader = "Fri, 13 Mar 2026 07:59:00 GMT")

        try {
            repository.syncAttendees()
            error("Expected SyncRateLimitedException")
        } catch (e: Exception) {
            assertThat(e).isInstanceOf(SyncRateLimitedException::class.java)
            assertThat((e as SyncRateLimitedException).retryAfterMillis).isNull()
        }
    }

    @Test
    fun rethrowsNon429HttpExceptionUnchanged() = runTest {
        val expected =
            HttpException(
                Response.error<MobileSyncResponse>(
                    500,
                    ResponseBody.create(
                        "application/json".toMediaType(),
                        """{"error":"server_error"}"""
                    )
                )
            )

        repository =
            CurrentPhoenixSyncRepository(
                remoteDataSource =
                    PhoenixMobileRemoteDataSource(
                        object : PhoenixMobileApi {
                            override suspend fun login(body: MobileLoginRequest): MobileLoginResponse =
                                error("Not used in this test")

                            override suspend fun syncAttendees(since: String?): MobileSyncResponse {
                                throw expected
                            }

                            override suspend fun uploadScans(
                                body: UploadScansRequest
                            ): UploadScansResponse = error("Not used in this test")
                        }
                    ),
                scannerDao = database.scannerDao(),
                sessionRepository = fixedSessionRepository(),
                clock = Clock.systemUTC()
            )

        try {
            repository.syncAttendees()
            error("Expected HttpException")
        } catch (e: Exception) {
            assertThat(e).isSameInstanceAs(expected)
        }
    }

    @Test
    fun failedSyncLeavesSeededAttendeeAndMetadataUnchanged() = runTest {
        database.scannerDao().upsertAttendees(
            listOf(
                attendeeEntity(
                    id = 501,
                    eventId = 5,
                    ticketCode = "VG-SEED-501",
                    firstName = "Seed",
                    updatedAt = "2026-03-13T07:59:00Z"
                )
            )
        )
        database.scannerDao().upsertSyncMetadata(
            SyncMetadataEntity(
                eventId = 5,
                lastServerTime = "2026-03-13T08:00:00Z",
                lastSuccessfulSyncAt = "2026-03-13T08:00:00Z",
                lastSyncType = "full",
                attendeeCount = 1
            )
        )

        val expected =
            HttpException(
                Response.error<MobileSyncResponse>(
                    500,
                    ResponseBody.create(
                        "application/json".toMediaType(),
                        """{"error":"server_error"}"""
                    )
                )
            )

        repository =
            CurrentPhoenixSyncRepository(
                remoteDataSource =
                    PhoenixMobileRemoteDataSource(
                        object : PhoenixMobileApi {
                            override suspend fun login(body: MobileLoginRequest): MobileLoginResponse =
                                error("Not used in this test")

                            override suspend fun syncAttendees(since: String?): MobileSyncResponse {
                                throw expected
                            }

                            override suspend fun uploadScans(
                                body: UploadScansRequest
                            ): UploadScansResponse = error("Not used in this test")
                        }
                    ),
                scannerDao = database.scannerDao(),
                sessionRepository = fixedSessionRepository(),
                clock = Clock.systemUTC()
            )

        try {
            repository.syncAttendees()
            error("Expected HttpException")
        } catch (e: Exception) {
            assertThat(e).isSameInstanceAs(expected)
        }

        val attendeeAfterFailure = database.scannerDao().findAttendee(5, "VG-SEED-501")
        val metadataAfterFailure = database.scannerDao().loadSyncMetadata(5)

        assertThat(attendeeAfterFailure?.id).isEqualTo(501)
        assertThat(attendeeAfterFailure?.updatedAt).isEqualTo("2026-03-13T07:59:00Z")
        assertThat(metadataAfterFailure?.lastServerTime).isEqualTo("2026-03-13T08:00:00Z")
        assertThat(metadataAfterFailure?.attendeeCount).isEqualTo(1)
    }

    private fun buildRepository(sessionRepository: SessionRepository): CurrentPhoenixSyncRepository =
        CurrentPhoenixSyncRepository(
            remoteDataSource = PhoenixMobileRemoteDataSource(api),
            scannerDao = database.scannerDao(),
            sessionRepository = sessionRepository,
            clock = Clock.systemUTC()
        )

    private fun buildRateLimitedRepository(retryAfterHeader: String?): CurrentPhoenixSyncRepository {
        val rateLimitedApi =
            object : PhoenixMobileApi {
                override suspend fun login(body: MobileLoginRequest): MobileLoginResponse =
                    error("Not used in this test")

                override suspend fun syncAttendees(since: String?): MobileSyncResponse {
                    val responseBody =
                        ResponseBody.create(
                            "application/json".toMediaType(),
                            """{"error":"rate_limited"}"""
                        )
                    val rawResponse =
                        okhttp3.Response.Builder()
                            .request(Request.Builder().url("https://example.test/api/v1/mobile/attendees").build())
                            .protocol(Protocol.HTTP_1_1)
                            .code(429)
                            .message("Too Many Requests")
                            .apply { if (retryAfterHeader != null) header("Retry-After", retryAfterHeader) }
                            .build()
                    val response = Response.error<MobileSyncResponse>(responseBody, rawResponse)
                    throw HttpException(response)
                }

                override suspend fun uploadScans(body: UploadScansRequest): UploadScansResponse =
                    error("Not used in this test")
            }

        return CurrentPhoenixSyncRepository(
            remoteDataSource = PhoenixMobileRemoteDataSource(rateLimitedApi),
            scannerDao = database.scannerDao(),
            sessionRepository = fixedSessionRepository(),
            clock = Clock.fixed(Instant.parse("2026-03-13T08:00:00Z"), ZoneOffset.UTC)
        )
    }

    private fun fixedSessionRepository(): SessionRepository =
        object : SessionRepository {
            override suspend fun login(eventId: Long, credential: String): ScannerSession = sampleSession()

            override suspend fun currentSession(): ScannerSession = sampleSession()

            override suspend fun logout() = Unit
        }

    private fun noSessionRepository(): SessionRepository =
        object : SessionRepository {
            override suspend fun login(eventId: Long, credential: String): ScannerSession = sampleSession()

            override suspend fun currentSession(): ScannerSession? = null

            override suspend fun logout() = Unit
        }

    private fun sampleSession(): ScannerSession =
        ScannerSession(
            eventId = 5,
            eventName = "Voelgoed Live",
            expiresInSeconds = 3600,
            authenticatedAtEpochMillis = 1_773_388_800_000,
            expiresAtEpochMillis = 1_773_392_400_000
        )

    private fun attendeeEntity(
        id: Long,
        eventId: Long,
        ticketCode: String,
        firstName: String,
        updatedAt: String
    ) = AttendeeDto(
        id = id,
        event_id = eventId,
        ticket_code = ticketCode,
        first_name = firstName,
        last_name = "User",
        email = "seed@example.com",
        ticket_type = "General",
        allowed_checkins = 1,
        checkins_remaining = 1,
        payment_status = "completed",
        is_currently_inside = false,
        checked_in_at = null,
        checked_out_at = null,
        updated_at = updatedAt
    ).toEntity()

    private class FakePhoenixMobileApi : PhoenixMobileApi {
        var lastSince: String? = null
        var syncResponse: MobileSyncResponse =
            MobileSyncResponse(
                data = null,
                error = "sync_missing",
                message = "Not configured"
            )

        override suspend fun login(body: MobileLoginRequest): MobileLoginResponse =
            MobileLoginResponse(
                data =
                    MobileLoginPayload(
                        token = "unused",
                        event_id = 5,
                        event_name = "Voelgoed Live",
                        expires_in = 3600
                    ),
                error = null,
                message = null
            )

        override suspend fun syncAttendees(since: String?): MobileSyncResponse {
            lastSince = since
            return syncResponse
        }

        override suspend fun uploadScans(body: UploadScansRequest): UploadScansResponse {
            error("Not used in this test")
        }
    }
}
