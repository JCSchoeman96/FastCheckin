package za.co.voelgoed.fastcheck.data.repository

import android.content.Context
import androidx.room.Room
import androidx.sqlite.db.SupportSQLiteDatabase
import androidx.sqlite.db.SimpleSQLiteQuery
import androidx.test.core.app.ApplicationProvider
import com.google.common.truth.Truth.assertThat
import java.time.Clock
import java.time.Instant
import java.time.ZoneOffset
import kotlinx.coroutines.CancellationException
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
import za.co.voelgoed.fastcheck.data.local.LocalAdmissionOverlayEntity
import za.co.voelgoed.fastcheck.domain.model.LocalAdmissionOverlayState
import za.co.voelgoed.fastcheck.core.network.PhoenixMobileApi
import za.co.voelgoed.fastcheck.core.sync.AttendeeSyncBootstrapStateHub
import za.co.voelgoed.fastcheck.data.local.SyncMetadataEntity
import za.co.voelgoed.fastcheck.data.mapper.toEntity
import za.co.voelgoed.fastcheck.data.remote.AttendeeDto
import za.co.voelgoed.fastcheck.data.remote.AttendeeInvalidationDto
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
                        sync_type = "full",
                        next_cursor = null
                    ),
                error = null,
                message = null
            )

        val status = repository.syncAttendees(AttendeeSyncMode.INCREMENTAL)
        val attendee = database.scannerDao().findAttendee(5, "VG-100")
        val metadata = database.scannerDao().loadSyncMetadata(5)

        assertThat(api.lastSince).isNull()
        assertThat(api.syncCalls.single().limit).isEqualTo(500)
        assertThat(attendee?.ticketCode).isEqualTo("VG-100")
        assertThat(metadata?.lastServerTime).isEqualTo("2026-03-13T08:10:00Z")
        assertThat(metadata?.lastSyncType).isEqualTo("full")
        assertThat(status?.attendeeCount).isEqualTo(1)
        assertThat(status?.syncType).isEqualTo("full")
    }

    /**
     * Regression: invalidations must be applied before attendee upserts for a page. If the same
     * `ticket_code` appears in both lists (tombstone + fresh row), upsert-then-delete would leave
     * no row; delete-then-upsert preserves the server row.
     */
    @Test
    fun syncAppliesInvalidationsBeforeAttendeeUpsertsForSameTicketCode() = runTest {
        database.scannerDao().upsertAttendees(
            listOf(
                attendeeEntity(
                    id = 1L,
                    eventId = 5,
                    ticketCode = "T-ORDER",
                    firstName = "Old",
                    updatedAt = "2026-03-13T07:00:00Z"
                )
            )
        )
        database.scannerDao().upsertSyncMetadata(
            metadataRow(
                eventId = 5,
                lastServerTime = "2026-03-13T08:00:00Z",
                lastSuccessfulSyncAt = "2026-03-13T08:00:00Z",
                lastSyncType = "full",
                attendeeCount = 1
            )
        )

        api.syncResponse =
            MobileSyncResponse(
                data =
                    MobileSyncPayload(
                        server_time = "2026-03-13T08:15:00Z",
                        invalidations =
                            listOf(
                                AttendeeInvalidationDto(
                                    id = 10,
                                    event_id = 5,
                                    attendee_id = 1,
                                    ticket_code = "T-ORDER",
                                    change_type = "ineligible",
                                    reason_code = "source_missing_from_authoritative_sync",
                                    effective_at = "2026-03-13T08:14:00Z",
                                    source_sync_run_id = null
                                )
                            ),
                        attendees =
                            listOf(
                                AttendeeDto(
                                    id = 2,
                                    event_id = 5,
                                    ticket_code = "T-ORDER",
                                    first_name = "New",
                                    last_name = "Row",
                                    email = "n@example.com",
                                    ticket_type = "General",
                                    allowed_checkins = 1,
                                    checkins_remaining = 1,
                                    payment_status = "completed",
                                    is_currently_inside = false,
                                    checked_in_at = null,
                                    checked_out_at = null,
                                    updated_at = "2026-03-13T08:14:30Z"
                                )
                            ),
                        count = 1,
                        sync_type = "incremental",
                        next_cursor = null,
                        invalidations_checkpoint = 10L,
                        event_sync_version = 3L
                    ),
                error = null,
                message = null
            )

        repository.syncAttendees(AttendeeSyncMode.INCREMENTAL)

        val after = database.scannerDao().findAttendee(5, "T-ORDER")
        assertThat(after).isNotNull()
        assertThat(after?.id).isEqualTo(2)
        assertThat(after?.firstName).isEqualTo("New")
    }

    @Test
    fun incrementalSyncUsesStoredLastServerTimeWatermark() = runTest {
        database.scannerDao().upsertSyncMetadata(
            metadataRow(
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
                        sync_type = "incremental",
                        next_cursor = null
                    ),
                error = null,
                message = null
            )

        val status = repository.syncAttendees(AttendeeSyncMode.INCREMENTAL)

        assertThat(api.lastSince).isEqualTo("2026-03-13T08:00:00Z")
        assertThat(api.syncCalls.single().limit).isEqualTo(500)
        assertThat(status?.lastSuccessfulSyncAt).isEqualTo("2026-03-13T08:20:00Z")
        assertThat(database.scannerDao().loadSyncMetadata(5)?.lastSyncType).isEqualTo("incremental")
    }

    @Test
    fun incrementalSyncWithNoFetchedRowsKeepsCachedAttendeeCount() = runTest {
        database.scannerDao().upsertAttendees(
            listOf(
                attendeeEntity(id = 1001, eventId = 5, ticketCode = "VG-CACHED-001"),
                attendeeEntity(id = 1002, eventId = 5, ticketCode = "VG-CACHED-002"),
                attendeeEntity(id = 1003, eventId = 5, ticketCode = "VG-CACHED-003")
            )
        )
        database.scannerDao().upsertSyncMetadata(
            metadataRow(
                eventId = 5,
                lastServerTime = "2026-03-13T08:00:00Z",
                lastSuccessfulSyncAt = "2026-03-13T08:00:00Z",
                lastSyncType = "full",
                attendeeCount = 3
            )
        )

        api.syncResponse =
            MobileSyncResponse(
                data =
                    MobileSyncPayload(
                        server_time = "2026-03-13T08:22:00Z",
                        attendees = emptyList(),
                        count = 0,
                        sync_type = "incremental",
                        next_cursor = null,
                        invalidations = emptyList(),
                        invalidations_checkpoint = 0L,
                        event_sync_version = 4L
                    ),
                error = null,
                message = null
            )

        val status = repository.syncAttendees(AttendeeSyncMode.INCREMENTAL)

        assertThat(status?.attendeeCount).isEqualTo(3)
        assertThat(database.scannerDao().loadSyncMetadata(5)?.attendeeCount).isEqualTo(3)
    }

    @Test
    fun syncAttendeesWithoutSessionReturnsNullAndDoesNotWrite() = runTest {
        repository = buildRepository(sessionRepository = noSessionRepository())

        val status = repository.syncAttendees(AttendeeSyncMode.INCREMENTAL)

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
                        sync_type = "full",
                        next_cursor = null
                    ),
                error = null,
                message = null
            )

        repository.syncAttendees(AttendeeSyncMode.INCREMENTAL)

        val attendee = database.scannerDao().findAttendee(5, "VG-ROW-12")
        val metadata = database.scannerDao().loadSyncMetadata(5)

        assertThat(attendee).isNotNull()
        assertThat(attendee?.id).isEqualTo(12)
        assertThat(metadata).isNotNull()
        assertThat(metadata?.eventId).isEqualTo(5)
        assertThat(metadata?.attendeeCount).isEqualTo(1)
    }

    @Test
    fun incrementalSyncUpdatesAttendeeRowWhenSameServerIdReturnsUpdatedFields() = runTest {
        database.scannerDao().upsertSyncMetadata(
            metadataRow(
                eventId = 5,
                lastServerTime = "2026-03-13T08:00:00Z",
                lastSuccessfulSyncAt = "2026-03-13T08:00:00Z",
                lastSyncType = "full",
                attendeeCount = 0
            )
        )

        api.syncResponse =
            MobileSyncResponse(
                data =
                    MobileSyncPayload(
                        server_time = "2026-03-13T08:35:00Z",
                        attendees =
                            listOf(
                                AttendeeDto(
                                    id = 500,
                                    event_id = 5,
                                    ticket_code = "VG-SAME-500",
                                    first_name = "Original",
                                    last_name = "Name",
                                    email = "same@example.com",
                                    ticket_type = "General",
                                    allowed_checkins = 1,
                                    checkins_remaining = 1,
                                    payment_status = "completed",
                                    is_currently_inside = false,
                                    checked_in_at = null,
                                    checked_out_at = null,
                                    updated_at = "2026-03-13T08:34:00Z"
                                )
                            ),
                        count = 1,
                        sync_type = "incremental",
                        next_cursor = null
                    ),
                error = null,
                message = null
            )

        repository.syncAttendees(AttendeeSyncMode.INCREMENTAL)
        assertThat(database.scannerDao().findAttendee(5, "VG-SAME-500")?.firstName).isEqualTo("Original")

        api.syncResponse =
            MobileSyncResponse(
                data =
                    MobileSyncPayload(
                        server_time = "2026-03-13T08:36:00Z",
                        attendees =
                            listOf(
                                AttendeeDto(
                                    id = 500,
                                    event_id = 5,
                                    ticket_code = "VG-SAME-500",
                                    first_name = "Updated",
                                    last_name = "Name",
                                    email = "same@example.com",
                                    ticket_type = "General",
                                    allowed_checkins = 1,
                                    checkins_remaining = 1,
                                    payment_status = "completed",
                                    is_currently_inside = true,
                                    checked_in_at = null,
                                    checked_out_at = null,
                                    updated_at = "2026-03-13T08:35:00Z"
                                )
                            ),
                        count = 1,
                        sync_type = "incremental",
                        next_cursor = null
                    ),
                error = null,
                message = null
            )

        repository.syncAttendees(AttendeeSyncMode.INCREMENTAL)

        val row = database.scannerDao().findAttendee(5, "VG-SAME-500")
        assertThat(row?.firstName).isEqualTo("Updated")
        assertThat(row?.isCurrentlyInside).isTrue()
    }

    @Test
    fun syncCanonicalizesTicketCodeBeforePersistingLocalLookupKey() = runTest {
        api.syncResponse =
            MobileSyncResponse(
                data =
                    MobileSyncPayload(
                        server_time = "2026-03-13T08:31:00Z",
                        attendees =
                            listOf(
                                AttendeeDto(
                                    id = 44,
                                    event_id = 5,
                                    ticket_code = " \tVG-TRIM-44\r\n",
                                    first_name = "Trim",
                                    last_name = "Case",
                                    email = "trim@example.com",
                                    ticket_type = "General",
                                    allowed_checkins = 1,
                                    checkins_remaining = 1,
                                    payment_status = "completed",
                                    is_currently_inside = false,
                                    checked_in_at = null,
                                    checked_out_at = null,
                                    updated_at = "2026-03-13T08:30:00Z"
                                )
                            ),
                        count = 1,
                        sync_type = "full",
                        next_cursor = null
                    ),
                error = null,
                message = null
            )

        repository.syncAttendees(AttendeeSyncMode.INCREMENTAL)

        assertThat(database.scannerDao().findAttendee(5, "VG-TRIM-44")?.id).isEqualTo(44)
        assertThat(database.scannerDao().findAttendee(5, " \tVG-TRIM-44\r\n")).isNull()
    }

    @Test
    fun pagedSyncFetchesUntilCursorExhaustedAndPersistsAllPages() = runTest {
        api.pagedResponses =
            mutableListOf(
                MobileSyncResponse(
                    data =
                        MobileSyncPayload(
                            server_time = "2026-03-13T08:40:00Z",
                            attendees =
                                listOf(
                                    attendeeDto(1001, "VG-PAGE-001"),
                                    attendeeDto(1002, "VG-PAGE-002")
                                ),
                            count = 2,
                            sync_type = "full",
                            next_cursor = "cursor-1"
                        ),
                    error = null,
                    message = null
                ),
                MobileSyncResponse(
                    data =
                        MobileSyncPayload(
                            server_time = "2026-03-13T08:40:00Z",
                            attendees =
                                listOf(
                                    attendeeDto(1003, "VG-PAGE-003"),
                                    attendeeDto(1004, "VG-PAGE-004")
                                ),
                            count = 2,
                            sync_type = "full",
                            next_cursor = "cursor-2"
                        ),
                    error = null,
                    message = null
                ),
                MobileSyncResponse(
                    data =
                        MobileSyncPayload(
                            server_time = "2026-03-13T08:40:00Z",
                            attendees = listOf(attendeeDto(1005, "VG-PAGE-005")),
                            count = 1,
                            sync_type = "full",
                            next_cursor = null
                        ),
                    error = null,
                    message = null
                )
            )

        val status = repository.syncAttendees(AttendeeSyncMode.INCREMENTAL)

        assertThat(api.syncCalls).hasSize(3)
        assertAllSyncCallsUsePageLimit()
        assertThat(api.syncCalls[0].cursor).isNull()
        assertThat(api.syncCalls[1].cursor).isEqualTo("cursor-1")
        assertThat(api.syncCalls[2].cursor).isEqualTo("cursor-2")
        assertThat(database.scannerDao().findAttendee(5, "VG-PAGE-005")).isNotNull()
        assertThat(database.scannerDao().loadSyncMetadata(5)?.attendeeCount).isEqualTo(5)
        assertThat(status?.attendeeCount).isEqualTo(5)
    }

    @Test
    fun pagedSyncFailsFastWhenCursorRepeats() = runTest {
        database.scannerDao().upsertAttendees(
            listOf(
                attendeeEntity(
                    id = 601,
                    eventId = 5,
                    ticketCode = "VG-SEED-601",
                    firstName = "Seed",
                    updatedAt = "2026-03-13T07:59:00Z"
                )
            )
        )
        database.scannerDao().upsertSyncMetadata(
            metadataRow(
                eventId = 5,
                lastServerTime = "2026-03-13T08:00:00Z",
                lastSuccessfulSyncAt = "2026-03-13T08:00:00Z",
                lastSyncType = "full",
                attendeeCount = 1
            )
        )

        api.pagedResponses =
            mutableListOf(
                MobileSyncResponse(
                    data =
                        MobileSyncPayload(
                            server_time = "2026-03-13T08:40:00Z",
                            attendees = listOf(attendeeDto(1001, "VG-PAGE-001")),
                            count = 1,
                            sync_type = "full",
                            next_cursor = "cursor-1"
                        ),
                    error = null,
                    message = null
                ),
                MobileSyncResponse(
                    data =
                        MobileSyncPayload(
                            server_time = "2026-03-13T08:40:00Z",
                            attendees = listOf(attendeeDto(1002, "VG-PAGE-002")),
                            count = 1,
                            sync_type = "full",
                            next_cursor = "cursor-1"
                        ),
                    error = null,
                    message = null
                )
            )

        val failure = runCatching { repository.syncAttendees(AttendeeSyncMode.INCREMENTAL) }.exceptionOrNull()
        val exception = failure as SyncPaginationException
        val seededAttendee = database.scannerDao().findAttendee(5, "VG-SEED-601")
        val firstPagedAttendee = database.scannerDao().findAttendee(5, "VG-PAGE-001")
        val secondPagedAttendee = database.scannerDao().findAttendee(5, "VG-PAGE-002")
        val metadataAfterFailure = database.scannerDao().loadSyncMetadata(5)

        assertThat(failure).isInstanceOf(SyncPaginationException::class.java)
        assertThat(exception.message).contains("repeated pagination cursor")
        assertThat(exception.message).contains("cursor-1")
        assertThat(countAttendeesForEvent(5)).isEqualTo(2)
        assertThat(seededAttendee?.id).isEqualTo(601)
        assertThat(seededAttendee?.updatedAt).isEqualTo("2026-03-13T07:59:00Z")
        assertThat(firstPagedAttendee?.id).isEqualTo(1001)
        assertThat(secondPagedAttendee).isNull()
        assertThat(metadataAfterFailure?.lastServerTime).isEqualTo("2026-03-13T08:00:00Z")
        assertThat(metadataAfterFailure?.attendeeCount).isEqualTo(1)
        assertThat(metadataAfterFailure?.consecutiveFailures).isEqualTo(0)
        assertThat(metadataAfterFailure?.consecutiveIntegrityFailures).isEqualTo(1)
        assertThat(metadataAfterFailure?.lastErrorCode).isEqualTo("integrity")
    }

    @Test
    fun pagedSyncAbortsBeforePage101WhenMaxPageCountIsExceeded() = runTest {
        database.scannerDao().upsertAttendees(
            listOf(
                attendeeEntity(
                    id = 602,
                    eventId = 5,
                    ticketCode = "VG-SEED-602",
                    firstName = "Seed",
                    updatedAt = "2026-03-13T07:58:00Z"
                )
            )
        )
        database.scannerDao().upsertSyncMetadata(
            metadataRow(
                eventId = 5,
                lastServerTime = "2026-03-13T08:00:00Z",
                lastSuccessfulSyncAt = "2026-03-13T08:00:00Z",
                lastSyncType = "full",
                attendeeCount = 1
            )
        )

        api.pagedResponses =
            (1..100).map { page ->
                MobileSyncResponse(
                    data =
                        MobileSyncPayload(
                            server_time = "2026-03-13T08:40:00Z",
                            attendees = listOf(attendeeDto(2000L + page, "VG-MAX-${page.toString().padStart(3, '0')}")),
                            count = 1,
                            sync_type = "full",
                            next_cursor = "cursor-$page"
                        ),
                    error = null,
                    message = null
                )
            }.toMutableList()

        val failure = runCatching { repository.syncAttendees(AttendeeSyncMode.INCREMENTAL) }.exceptionOrNull()
        val exception = failure as SyncPaginationException
        val seededAttendee = database.scannerDao().findAttendee(5, "VG-SEED-602")
        val firstPagedAttendee = database.scannerDao().findAttendee(5, "VG-MAX-001")
        val lastPagedAttendee = database.scannerDao().findAttendee(5, "VG-MAX-100")
        val metadataAfterFailure = database.scannerDao().loadSyncMetadata(5)

        assertThat(failure).isInstanceOf(SyncPaginationException::class.java)
        assertThat(exception.message).contains("max page count 100")
        assertThat(exception.message).contains("page size 500")
        assertThat(exception.message).contains("aborted to avoid an infinite loop")
        assertThat(api.syncCalls).hasSize(100)
        assertAllSyncCallsUsePageLimit()
        assertThat(api.syncCalls.last().cursor).isEqualTo("cursor-99")
        assertThat(countAttendeesForEvent(5)).isEqualTo(101)
        assertThat(seededAttendee?.id).isEqualTo(602)
        assertThat(seededAttendee?.updatedAt).isEqualTo("2026-03-13T07:58:00Z")
        assertThat(firstPagedAttendee?.id).isEqualTo(2001)
        assertThat(lastPagedAttendee?.id).isEqualTo(2100)
        assertThat(metadataAfterFailure?.lastServerTime).isEqualTo("2026-03-13T08:00:00Z")
        assertThat(metadataAfterFailure?.attendeeCount).isEqualTo(1)
        assertThat(metadataAfterFailure?.consecutiveFailures).isEqualTo(0)
        assertThat(metadataAfterFailure?.consecutiveIntegrityFailures).isEqualTo(1)
        assertThat(metadataAfterFailure?.lastErrorCode).isEqualTo("integrity")
    }

    @Test
    fun pagedSyncKeepsEarlierPagesWhenLaterPageHasInvalidTicketCode() = runTest {
        database.scannerDao().upsertSyncMetadata(
            metadataRow(
                eventId = 5,
                lastServerTime = "2026-03-13T08:00:00Z",
                lastSuccessfulSyncAt = "2026-03-13T08:00:00Z",
                lastSyncType = "full",
                attendeeCount = 0
            )
        )

        api.pagedResponses =
            mutableListOf(
                MobileSyncResponse(
                    data =
                        MobileSyncPayload(
                            server_time = "2026-03-13T08:40:00Z",
                            attendees = listOf(attendeeDto(1101, "VG-VALID-001")),
                            count = 1,
                            sync_type = "full",
                            next_cursor = "cursor-1"
                        ),
                    error = null,
                    message = null
                ),
                MobileSyncResponse(
                    data =
                        MobileSyncPayload(
                            server_time = "2026-03-13T08:40:00Z",
                            attendees = listOf(attendeeDto(1102, " \t \r\n ")),
                            count = 1,
                            sync_type = "full",
                            next_cursor = null
                        ),
                    error = null,
                    message = null
                )
            )

        val failure = runCatching { repository.syncAttendees(AttendeeSyncMode.INCREMENTAL) }.exceptionOrNull()
        val metadataAfterFailure = database.scannerDao().loadSyncMetadata(5)

        assertThat(failure).isInstanceOf(IllegalArgumentException::class.java)
        assertThat(failure?.message).contains("invalid ticket_code")
        assertThat(database.scannerDao().findAttendee(5, "VG-VALID-001")?.id).isEqualTo(1101)
        assertThat(countAttendeesForEvent(5)).isEqualTo(1)
        assertThat(metadataAfterFailure?.lastServerTime).isEqualTo("2026-03-13T08:00:00Z")
        assertThat(metadataAfterFailure?.attendeeCount).isEqualTo(0)
        assertThat(metadataAfterFailure?.consecutiveFailures).isEqualTo(1)
        assertThat(metadataAfterFailure?.consecutiveIntegrityFailures).isEqualTo(0)
        assertThat(metadataAfterFailure?.lastErrorCode).isEqualTo("sync_failed")
    }

    @Test
    fun mapsHttp429ToSyncRateLimitedExceptionWithoutRetryAfterHeader() = runTest {
        repository = buildRateLimitedRepository(retryAfterHeader = null)

        try {
            repository.syncAttendees(AttendeeSyncMode.INCREMENTAL)
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
            repository.syncAttendees(AttendeeSyncMode.INCREMENTAL)
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
            repository.syncAttendees(AttendeeSyncMode.INCREMENTAL)
            error("Expected SyncRateLimitedException")
        } catch (e: Exception) {
            assertThat(e).isInstanceOf(SyncRateLimitedException::class.java)
            assertThat((e as SyncRateLimitedException).retryAfterMillis).isNull()
        }
    }

    @Test
    fun mapsHttp429ToSyncRateLimitedExceptionWithNonPositiveAndMalformedRetryAfterAsNull() = runTest {
        val invalidHeaders = listOf("", "0", "-5", "abc")

        invalidHeaders.forEach { header ->
            repository = buildRateLimitedRepository(retryAfterHeader = header)

            try {
                repository.syncAttendees(AttendeeSyncMode.INCREMENTAL)
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
            repository.syncAttendees(AttendeeSyncMode.INCREMENTAL)
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
            repository.syncAttendees(AttendeeSyncMode.INCREMENTAL)
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

                            override suspend fun syncAttendees(
                            since: String?,
                            cursor: String?,
                            sinceInvalidationId: Long,
                            limit: Int
                        ): MobileSyncResponse {
                                throw expected
                            }

                            override suspend fun uploadScans(
                                body: UploadScansRequest
                            ): Response<UploadScansResponse> = error("Not used in this test")
                        }
                    ),
                scannerDao = database.scannerDao(),
                sessionRepository = fixedSessionRepository(),
                clock = Clock.systemUTC(),
                bootstrapStateHub = AttendeeSyncBootstrapStateHub()
            )

        try {
            repository.syncAttendees(AttendeeSyncMode.INCREMENTAL)
            error("Expected HttpException")
        } catch (e: Exception) {
            assertThat(e).isSameInstanceAs(expected)
        }
    }

    @Test
    fun structuredCancellationRethrowsWithoutIncrementingSyncFailureCounters() = runTest {
        database.scannerDao().upsertSyncMetadata(
            metadataRow(
                eventId = 5,
                lastServerTime = "2026-03-13T08:00:00Z",
                lastSuccessfulSyncAt = "2026-03-13T08:00:00Z",
                lastSyncType = "full",
                attendeeCount = 1
            )
        )

        repository =
            CurrentPhoenixSyncRepository(
                remoteDataSource =
                    PhoenixMobileRemoteDataSource(
                        object : PhoenixMobileApi {
                            override suspend fun login(body: MobileLoginRequest): MobileLoginResponse =
                                error("Not used in this test")

                            override suspend fun syncAttendees(
                            since: String?,
                            cursor: String?,
                            sinceInvalidationId: Long,
                            limit: Int
                        ): MobileSyncResponse {
                                throw CancellationException("caller cancelled")
                            }

                            override suspend fun uploadScans(
                                body: UploadScansRequest
                            ): Response<UploadScansResponse> = error("Not used in this test")
                        }
                    ),
                scannerDao = database.scannerDao(),
                sessionRepository = fixedSessionRepository(),
                clock = Clock.systemUTC(),
                bootstrapStateHub = AttendeeSyncBootstrapStateHub()
            )

        val failure = runCatching { repository.syncAttendees(AttendeeSyncMode.INCREMENTAL) }.exceptionOrNull()
        val metadataAfterFailure = database.scannerDao().loadSyncMetadata(5)

        assertThat(failure).isInstanceOf(CancellationException::class.java)
        assertThat(metadataAfterFailure?.consecutiveFailures).isEqualTo(0)
        assertThat(metadataAfterFailure?.consecutiveIntegrityFailures).isEqualTo(0)
        assertThat(metadataAfterFailure?.lastErrorCode).isNull()
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
            metadataRow(
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

                            override suspend fun syncAttendees(
                            since: String?,
                            cursor: String?,
                            sinceInvalidationId: Long,
                            limit: Int
                        ): MobileSyncResponse {
                                throw expected
                            }

                            override suspend fun uploadScans(
                                body: UploadScansRequest
                            ): Response<UploadScansResponse> = error("Not used in this test")
                        }
                    ),
                scannerDao = database.scannerDao(),
                sessionRepository = fixedSessionRepository(),
                clock = Clock.systemUTC(),
                bootstrapStateHub = AttendeeSyncBootstrapStateHub()
            )

        try {
            repository.syncAttendees(AttendeeSyncMode.INCREMENTAL)
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
        assertThat(metadataAfterFailure?.consecutiveFailures).isEqualTo(1)
        assertThat(metadataAfterFailure?.consecutiveIntegrityFailures).isEqualTo(0)
        assertThat(metadataAfterFailure?.lastErrorCode).isEqualTo("http_500")
    }

    @Test
    fun confirmedOverlayRemovedAfterSyncWhenCatchUpPolicySatisfied() = runTest {
        database.scannerDao().upsertAttendees(
            listOf(
                attendeeEntity(
                    id = 10,
                    eventId = 5,
                    ticketCode = "VG-CATCH-10",
                    firstName = "Catch",
                    updatedAt = "2026-03-13T09:00:00Z"
                )
            )
        )
        database.scannerDao().upsertLocalAdmissionOverlay(
            LocalAdmissionOverlayEntity(
                eventId = 5,
                attendeeId = 10L,
                ticketCode = "VG-CATCH-10",
                idempotencyKey = "idem-catch-10",
                state = LocalAdmissionOverlayState.CONFIRMED_LOCAL_UNSYNCED.name,
                createdAtEpochMillis = 1_000L,
                overlayScannedAt = "2026-03-13T10:00:00Z",
                expectedRemainingAfterOverlay = 0,
                operatorName = "Op",
                entranceName = "Main"
            )
        )

        api.syncResponse =
            MobileSyncResponse(
                data =
                    MobileSyncPayload(
                        server_time = "2026-03-13T10:30:00Z",
                        attendees =
                            listOf(
                                AttendeeDto(
                                    id = 10,
                                    event_id = 5,
                                    ticket_code = "VG-CATCH-10",
                                    first_name = "Catch",
                                    last_name = "Up",
                                    email = "c@example.com",
                                    ticket_type = "VIP",
                                    allowed_checkins = 1,
                                    checkins_remaining = 0,
                                    payment_status = "completed",
                                    is_currently_inside = true,
                                    checked_in_at = "2026-03-13T10:00:30Z",
                                    checked_out_at = null,
                                    updated_at = "2026-03-13T10:30:00Z"
                                )
                            ),
                        count = 1,
                        sync_type = "incremental",
                        next_cursor = null
                    ),
                error = null,
                message = null
            )

        repository.syncAttendees(AttendeeSyncMode.INCREMENTAL)

        assertThat(database.scannerDao().findLocalAdmissionOverlayByIdempotencyKey("idem-catch-10")).isNull()
    }

    @Test
    fun confirmedOverlayRetainedWhenSyncedAttendeeHasNotCaughtUp() = runTest {
        database.scannerDao().upsertAttendees(
            listOf(
                attendeeEntity(
                    id = 11,
                    eventId = 5,
                    ticketCode = "VG-NOCATCH-11",
                    firstName = "No",
                    updatedAt = "2026-03-13T09:00:00Z"
                )
            )
        )
        database.scannerDao().upsertLocalAdmissionOverlay(
            LocalAdmissionOverlayEntity(
                eventId = 5,
                attendeeId = 11L,
                ticketCode = "VG-NOCATCH-11",
                idempotencyKey = "idem-nocatch-11",
                state = LocalAdmissionOverlayState.CONFIRMED_LOCAL_UNSYNCED.name,
                createdAtEpochMillis = 1_000L,
                overlayScannedAt = "2026-03-13T10:00:00Z",
                expectedRemainingAfterOverlay = 0,
                operatorName = "Op",
                entranceName = "Main"
            )
        )

        api.syncResponse =
            MobileSyncResponse(
                data =
                    MobileSyncPayload(
                        server_time = "2026-03-13T10:30:00Z",
                        attendees =
                            listOf(
                                AttendeeDto(
                                    id = 11,
                                    event_id = 5,
                                    ticket_code = "VG-NOCATCH-11",
                                    first_name = "No",
                                    last_name = "Catch",
                                    email = "n@example.com",
                                    ticket_type = "VIP",
                                    allowed_checkins = 1,
                                    checkins_remaining = 1,
                                    payment_status = "completed",
                                    is_currently_inside = false,
                                    checked_in_at = null,
                                    checked_out_at = null,
                                    updated_at = "2026-03-13T10:30:00Z"
                                )
                            ),
                        count = 1,
                        sync_type = "incremental",
                        next_cursor = null
                    ),
                error = null,
                message = null
            )

        repository.syncAttendees(AttendeeSyncMode.INCREMENTAL)

        val overlay = database.scannerDao().findLocalAdmissionOverlayByIdempotencyKey("idem-nocatch-11")
        assertThat(overlay).isNotNull()
        assertThat(overlay?.state).isEqualTo(LocalAdmissionOverlayState.CONFIRMED_LOCAL_UNSYNCED.name)
    }

    @Test
    fun syncAttendeesKeepsPersistedAttendeeWhenSyncMetadataUpsertFails() = runTest {
        database.scannerDao().upsertAttendees(
            listOf(
                attendeeEntity(
                    id = 700,
                    eventId = 5,
                    ticketCode = "VG-SEED-700",
                    firstName = "Seed",
                    updatedAt = "2026-03-13T07:50:00Z"
                )
            )
        )
        database.scannerDao().upsertSyncMetadata(
            metadataRow(
                eventId = 5,
                lastServerTime = "2026-03-13T07:50:00Z",
                lastSuccessfulSyncAt = "2026-03-13T07:50:00Z",
                lastSyncType = "full",
                attendeeCount = 1
            )
        )

        api.syncResponse =
            MobileSyncResponse(
                data =
                    MobileSyncPayload(
                        server_time = "2026-03-13T08:40:00Z",
                        attendees =
                            listOf(
                                AttendeeDto(
                                    id = 701,
                                    event_id = 5,
                                    ticket_code = "VG-NEW-701",
                                    first_name = "New",
                                    last_name = "User",
                                    email = "new@example.com",
                                    ticket_type = "VIP",
                                    allowed_checkins = 1,
                                    checkins_remaining = 1,
                                    payment_status = "completed",
                                    is_currently_inside = false,
                                    checked_in_at = null,
                                    checked_out_at = null,
                                    updated_at = "2026-03-13T08:39:00Z"
                                )
                            ),
                        count = 2,
                        sync_type = "incremental",
                        next_cursor = null
                    ),
                error = null,
                message = null
            )

        createAbortInsertOrUpdateTrigger(
            tableName = "sync_metadata",
            triggerName = "abort_sync_metadata_write"
        )

        val failure = runCatching { repository.syncAttendees(AttendeeSyncMode.INCREMENTAL) }.exceptionOrNull()
        val seededAttendee = database.scannerDao().findAttendee(5, "VG-SEED-700")
        val newAttendee = database.scannerDao().findAttendee(5, "VG-NEW-701")
        val metadata = database.scannerDao().loadSyncMetadata(5)

        assertThat(failure).isNotNull()
        assertThat(seededAttendee?.id).isEqualTo(700)
        assertThat(newAttendee?.id).isEqualTo(701)
        assertThat(metadata?.lastServerTime).isEqualTo("2026-03-13T07:50:00Z")
        assertThat(metadata?.attendeeCount).isEqualTo(1)
    }

    private fun metadataRow(
        eventId: Long,
        lastServerTime: String?,
        lastSuccessfulSyncAt: String?,
        lastSyncType: String?,
        attendeeCount: Int
    ): SyncMetadataEntity =
        SyncMetadataEntity(
            eventId = eventId,
            lastServerTime = lastServerTime,
            lastSuccessfulSyncAt = lastSuccessfulSyncAt,
            lastSyncType = lastSyncType,
            attendeeCount = attendeeCount,
            bootstrapCompletedAt = lastSuccessfulSyncAt,
            lastAttemptedSyncAt = lastSuccessfulSyncAt,
            consecutiveFailures = 0,
            lastErrorCode = null,
            lastErrorAt = null,
            lastFullReconcileAt = lastSuccessfulSyncAt,
            incrementalCyclesSinceFullReconcile = 0,
            consecutiveIntegrityFailures = 0,
            integrityFailuresInForegroundSession = 0
        )

    private fun buildRepository(sessionRepository: SessionRepository): CurrentPhoenixSyncRepository =
        CurrentPhoenixSyncRepository(
            remoteDataSource = PhoenixMobileRemoteDataSource(api),
            scannerDao = database.scannerDao(),
            sessionRepository = sessionRepository,
            clock = Clock.systemUTC(),
            bootstrapStateHub = AttendeeSyncBootstrapStateHub()
        )

    private fun buildRateLimitedRepository(retryAfterHeader: String?): CurrentPhoenixSyncRepository {
        val rateLimitedApi =
            object : PhoenixMobileApi {
                override suspend fun login(body: MobileLoginRequest): MobileLoginResponse =
                    error("Not used in this test")

                override suspend fun syncAttendees(
                            since: String?,
                            cursor: String?,
                            sinceInvalidationId: Long,
                            limit: Int
                        ): MobileSyncResponse {
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

                override suspend fun uploadScans(body: UploadScansRequest): Response<UploadScansResponse> =
                    error("Not used in this test")
            }

        return CurrentPhoenixSyncRepository(
            remoteDataSource = PhoenixMobileRemoteDataSource(rateLimitedApi),
            scannerDao = database.scannerDao(),
            sessionRepository = fixedSessionRepository(),
            clock = Clock.fixed(Instant.parse("2026-03-13T08:00:00Z"), ZoneOffset.UTC),
            bootstrapStateHub = AttendeeSyncBootstrapStateHub()
        )
    }

    private fun fixedSessionRepository(): SessionRepository =
        object : SessionRepository {
            override suspend fun login(eventId: Long, credential: String): ScannerSession = sampleSession()

            override suspend fun currentSession(): ScannerSession = sampleSession()

            override suspend fun logout() = Unit

            override suspend fun onAuthExpired() = Unit

            override suspend fun clearBlockedRestoredSession() = Unit
        }

    private fun noSessionRepository(): SessionRepository =
        object : SessionRepository {
            override suspend fun login(eventId: Long, credential: String): ScannerSession = sampleSession()

            override suspend fun currentSession(): ScannerSession? = null

            override suspend fun logout() = Unit

            override suspend fun onAuthExpired() = Unit

            override suspend fun clearBlockedRestoredSession() = Unit
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
        firstName: String = "Cached",
        updatedAt: String = "2026-03-13T08:00:00Z"
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

    private fun attendeeDto(id: Long, ticketCode: String): AttendeeDto =
        AttendeeDto(
            id = id,
            event_id = 5,
            ticket_code = ticketCode,
            first_name = "Paged",
            last_name = "User",
            email = "paged@example.com",
            ticket_type = "General",
            allowed_checkins = 1,
            checkins_remaining = 1,
            payment_status = "completed",
            is_currently_inside = false,
            checked_in_at = null,
            checked_out_at = null,
            updated_at = "2026-03-13T08:39:00Z"
        )

    private class FakePhoenixMobileApi : PhoenixMobileApi {
        data class SyncCall(
            val since: String?,
            val cursor: String?,
            val sinceInvalidationId: Long,
            val limit: Int
        )

        var lastSince: String? = null
        var lastSinceInvalidationId: Long = 0L
        val syncCalls: MutableList<SyncCall> = mutableListOf()
        var pagedResponses: MutableList<MobileSyncResponse> = mutableListOf()
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

        override suspend fun syncAttendees(
            since: String?,
            cursor: String?,
            sinceInvalidationId: Long,
            limit: Int
        ): MobileSyncResponse {
            lastSince = since
            lastSinceInvalidationId = sinceInvalidationId
            syncCalls += SyncCall(since = since, cursor = cursor, sinceInvalidationId = sinceInvalidationId, limit = limit)

            return if (pagedResponses.isNotEmpty()) {
                pagedResponses.removeFirst()
            } else {
                syncResponse
            }
        }

        override suspend fun uploadScans(body: UploadScansRequest): Response<UploadScansResponse> {
            error("Not used in this test")
        }
    }

    private fun createAbortInsertTrigger(tableName: String, triggerName: String) {
        writableDatabase().execSQL("DROP TRIGGER IF EXISTS $triggerName")
        writableDatabase().execSQL(
            """
            CREATE TRIGGER $triggerName
            BEFORE INSERT ON $tableName
            BEGIN
                SELECT RAISE(ABORT, '$triggerName');
            END
            """.trimIndent()
        )
    }

    /**
     * Room upsert on `sync_metadata` may take INSERT (no row yet) or UPDATE (row exists). Tests that
     * simulate write failure must abort both paths.
     */
    private fun createAbortInsertOrUpdateTrigger(tableName: String, triggerName: String) {
        val db = writableDatabase()
        db.execSQL("DROP TRIGGER IF EXISTS ${triggerName}_insert")
        db.execSQL("DROP TRIGGER IF EXISTS ${triggerName}_update")
        db.execSQL(
            """
            CREATE TRIGGER ${triggerName}_insert
            BEFORE INSERT ON $tableName
            BEGIN
                SELECT RAISE(ABORT, '$triggerName');
            END
            """.trimIndent()
        )
        db.execSQL(
            """
            CREATE TRIGGER ${triggerName}_update
            BEFORE UPDATE ON $tableName
            BEGIN
                SELECT RAISE(ABORT, '$triggerName');
            END
            """.trimIndent()
        )
    }

    private fun countAttendeesForEvent(eventId: Long): Int =
        writableDatabase().query(
            SimpleSQLiteQuery(
                "SELECT COUNT(*) FROM attendees WHERE eventId = ?",
                arrayOf(eventId)
            )
        ).use { cursor ->
            cursor.moveToFirst()
            cursor.getInt(0)
        }

    private fun assertAllSyncCallsUsePageLimit() {
        assertThat(api.syncCalls.map { it.limit }).containsExactlyElementsIn(List(api.syncCalls.size) { 500 })
    }

    private fun writableDatabase(): SupportSQLiteDatabase = database.openHelper.writableDatabase
}
