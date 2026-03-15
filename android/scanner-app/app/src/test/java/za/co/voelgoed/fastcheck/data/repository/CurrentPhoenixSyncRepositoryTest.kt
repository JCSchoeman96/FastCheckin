package za.co.voelgoed.fastcheck.data.repository

import android.content.Context
import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import com.google.common.truth.Truth.assertThat
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import za.co.voelgoed.fastcheck.core.database.FastCheckDatabase
import za.co.voelgoed.fastcheck.core.network.PhoenixMobileApi
import za.co.voelgoed.fastcheck.data.local.SyncMetadataEntity
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
        repository =
            CurrentPhoenixSyncRepository(
                remoteDataSource = PhoenixMobileRemoteDataSource(api),
                scannerDao = database.scannerDao(),
                sessionRepository =
                    object : SessionRepository {
                        override suspend fun login(eventId: Long, credential: String): ScannerSession =
                            sampleSession()

                        override suspend fun currentSession(): ScannerSession = sampleSession()

                        override suspend fun logout() = Unit
                    }
            )
    }

    @After
    fun tearDown() {
        database.close()
    }

    @Test
    fun initialSyncUsesNullWatermarkAndUpsertsAttendees() = runTest {
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

        assertThat(api.lastSince).isNull()
        assertThat(attendee?.ticketCode).isEqualTo("VG-100")
        assertThat(status?.attendeeCount).isEqualTo(1)
        assertThat(status?.syncType).isEqualTo("full")
    }

    @Test
    fun incrementalSyncUsesStoredWatermark() = runTest {
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

    private fun sampleSession(): ScannerSession =
        ScannerSession(
            eventId = 5,
            eventName = "Voelgoed Live",
            expiresInSeconds = 3600,
            authenticatedAtEpochMillis = 1_773_388_800_000,
            expiresAtEpochMillis = 1_773_392_400_000
        )

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
