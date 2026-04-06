package za.co.voelgoed.fastcheck.data.local

import android.content.Context
import androidx.room.Room
import androidx.sqlite.db.SupportSQLiteDatabase
import androidx.test.core.app.ApplicationProvider
import com.google.common.truth.Truth.assertThat
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import za.co.voelgoed.fastcheck.core.database.FastCheckDatabase
import za.co.voelgoed.fastcheck.domain.model.LocalAdmissionOverlayState

@RunWith(RobolectricTestRunner::class)
class ScannerDaoTest {
    private lateinit var database: FastCheckDatabase
    private lateinit var dao: ScannerDao

    @Before
    fun setUp() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        database =
            Room.inMemoryDatabaseBuilder(context, FastCheckDatabase::class.java)
                .allowMainThreadQueries()
                .build()
        dao = database.scannerDao()
    }

    @After
    fun tearDown() {
        database.close()
    }

    @Test
    fun upsertsAndFindsAttendeeByEventAndTicketCode() = runTest {
        dao.upsertAttendees(
            listOf(
                AttendeeEntity(
                    id = 1,
                    eventId = 5,
                    ticketCode = "VG-001",
                    firstName = "Jane",
                    lastName = "Doe",
                    email = "jane@example.com",
                    ticketType = "VIP",
                    allowedCheckins = 1,
                    checkinsRemaining = 1,
                    paymentStatus = "completed",
                    isCurrentlyInside = false,
                    checkedInAt = null,
                    checkedOutAt = null,
                    updatedAt = "2026-03-12T09:00:00Z"
                )
            )
        )

        val attendee = dao.findAttendee(5, "VG-001")

        assertThat(attendee).isNotNull()
        assertThat(attendee?.email).isEqualTo("jane@example.com")
    }

    @Test
    fun enforcesQueuedScanIdempotencyAndOrdersByCreatedAtThenId() = runTest {
        dao.insertQueuedScan(
            QueuedScanEntity(
                eventId = 5,
                ticketCode = "VG-002",
                idempotencyKey = "idem-2",
                createdAt = 200L,
                scannedAt = "2026-03-12T09:00:02Z",
                entranceName = "Main",
                operatorName = "Op 1"
            )
        )

        val duplicateInsert =
            dao.insertQueuedScan(
                QueuedScanEntity(
                    eventId = 5,
                    ticketCode = "VG-002",
                    idempotencyKey = "idem-2",
                    createdAt = 250L,
                    scannedAt = "2026-03-12T09:00:03Z",
                    entranceName = "Main",
                    operatorName = "Op 1"
                )
            )

        dao.insertQueuedScan(
            QueuedScanEntity(
                eventId = 5,
                ticketCode = "VG-001",
                idempotencyKey = "idem-1",
                createdAt = 100L,
                scannedAt = "2026-03-12T09:00:01Z",
                entranceName = "Main",
                operatorName = "Op 1"
            )
        )

        val queued = dao.loadQueuedScans()

        assertThat(duplicateInsert).isEqualTo(-1L)
        assertThat(queued.map { it.ticketCode }).containsExactly("VG-001", "VG-002").inOrder()
    }

    @Test
    fun persistsReplaySuppressionAndLatestFlushSnapshot() = runTest {
        dao.upsertReplaySuppression(
            LocalReplaySuppressionEntity(
                ticketCode = "VG-100",
                seenAtEpochMillis = 3_000L
            )
        )

        dao.replaceLatestFlushState(
            snapshot =
                LatestFlushSnapshotEntity(
                    executionStatus = "COMPLETED",
                    uploadedCount = 1,
                    retryableRemainingCount = 0,
                    authExpired = false,
                    backlogRemaining = false,
                    summaryMessage = "Flush completed.",
                    completedAt = "2026-03-12T09:10:00Z"
                ),
            outcomes =
                listOf(
                    RecentFlushOutcomeEntity(
                        outcomeOrder = 0,
                        idempotencyKey = "idem-3",
                        ticketCode = "VG-100",
                        outcome = "SUCCESS",
                        message = "Check-in successful",
                        reasonCode = "business_duplicate",
                        completedAt = "2026-03-12T09:10:00Z"
                    )
                )
        )

        val replaySuppression = dao.findReplaySuppression("VG-100")
        val snapshot = dao.loadLatestFlushSnapshot()
        val outcomes = dao.loadRecentFlushOutcomes()

        assertThat(replaySuppression?.seenAtEpochMillis).isEqualTo(3_000L)
        assertThat(snapshot?.summaryMessage).isEqualTo("Flush completed.")
        assertThat(outcomes.single().ticketCode).isEqualTo("VG-100")
        assertThat(outcomes.single().reasonCode).isEqualTo("business_duplicate")
    }

    @Test
    fun replaceLatestFlushStateReplacesRowsAndPreservesOutcomeOrdering() = runTest {
        dao.replaceLatestFlushState(
            snapshot =
                LatestFlushSnapshotEntity(
                    executionStatus = "COMPLETED",
                    uploadedCount = 1,
                    retryableRemainingCount = 0,
                    authExpired = false,
                    backlogRemaining = false,
                    summaryMessage = "First flush.",
                    completedAt = "2026-03-12T09:00:00Z"
                ),
            outcomes =
                listOf(
                    RecentFlushOutcomeEntity(
                        outcomeOrder = 0,
                        idempotencyKey = "old-idem",
                        ticketCode = "OLD-1",
                        outcome = "SUCCESS",
                        message = "Old result",
                        reasonCode = null,
                        completedAt = "2026-03-12T09:00:00Z"
                    )
                )
        )

        dao.replaceLatestFlushState(
            snapshot =
                LatestFlushSnapshotEntity(
                    executionStatus = "COMPLETED",
                    uploadedCount = 2,
                    retryableRemainingCount = 0,
                    authExpired = false,
                    backlogRemaining = false,
                    summaryMessage = "Second flush.",
                    completedAt = "2026-03-12T09:05:00Z"
                ),
            outcomes =
                listOf(
                    RecentFlushOutcomeEntity(
                        outcomeOrder = 0,
                        idempotencyKey = "idem-1",
                        ticketCode = "VG-001",
                        outcome = "DUPLICATE",
                        message = "Already processed",
                        reasonCode = "business_duplicate",
                        completedAt = "2026-03-12T09:05:00Z"
                    ),
                    RecentFlushOutcomeEntity(
                        outcomeOrder = 1,
                        idempotencyKey = "idem-2",
                        ticketCode = "VG-002",
                        outcome = "TERMINAL_ERROR",
                        message = "Payment invalid",
                        reasonCode = "payment_invalid",
                        completedAt = "2026-03-12T09:05:00Z"
                    )
                )
        )

        val outcomes = dao.loadRecentFlushOutcomes()

        assertThat(outcomes.map { it.ticketCode }).containsExactly("VG-001", "VG-002").inOrder()
        assertThat(outcomes.map { it.reasonCode })
            .containsExactly("business_duplicate", "payment_invalid")
            .inOrder()
        assertThat(outcomes).hasSize(2)
    }

    @Test
    fun upsertAttendeesAndSyncMetadataPersistsBothTablesViaSingleDaoEntrypoint() = runTest {
        dao.upsertAttendeesAndSyncMetadata(
            attendees =
                listOf(
                    AttendeeEntity(
                        id = 77,
                        eventId = 5,
                        ticketCode = "VG-TX-77",
                        firstName = "Taylor",
                        lastName = "Txn",
                        email = "taylor@example.com",
                        ticketType = "General",
                        allowedCheckins = 1,
                        checkinsRemaining = 1,
                        paymentStatus = "completed",
                        isCurrentlyInside = false,
                        checkedInAt = null,
                        checkedOutAt = null,
                        updatedAt = "2026-03-13T10:00:00Z"
                    )
                ),
            metadata =
                SyncMetadataEntity(
                    eventId = 5,
                    lastServerTime = "2026-03-13T10:01:00Z",
                    lastSuccessfulSyncAt = "2026-03-13T10:01:00Z",
                    lastSyncType = "full",
                    attendeeCount = 1
                )
        )

        val attendee = dao.findAttendee(5, "VG-TX-77")
        val metadata = dao.loadSyncMetadata(5)

        assertThat(attendee).isNotNull()
        assertThat(metadata).isNotNull()
        assertThat(metadata?.lastServerTime).isEqualTo("2026-03-13T10:01:00Z")
    }

    @Test
    fun upsertAttendeesAndSyncMetadataRollsBackAttendeeWriteWhenMetadataWriteFails() = runTest {
        createAbortInsertTrigger(
            tableName = "sync_metadata",
            triggerName = "abort_sync_metadata_insert"
        )

        val failure =
            runCatching {
                dao.upsertAttendeesAndSyncMetadata(
                    attendees =
                        listOf(
                            AttendeeEntity(
                                id = 88,
                                eventId = 5,
                                ticketCode = "VG-TX-88",
                                firstName = "Fail",
                                lastName = "Metadata",
                                email = "fail-metadata@example.com",
                                ticketType = "General",
                                allowedCheckins = 1,
                                checkinsRemaining = 1,
                                paymentStatus = "completed",
                                isCurrentlyInside = false,
                                checkedInAt = null,
                                checkedOutAt = null,
                                updatedAt = "2026-03-13T10:02:00Z"
                            )
                        ),
                    metadata =
                        SyncMetadataEntity(
                            eventId = 5,
                            lastServerTime = "2026-03-13T10:03:00Z",
                            lastSuccessfulSyncAt = "2026-03-13T10:03:00Z",
                            lastSyncType = "full",
                            attendeeCount = 1
                        )
                )
            }.exceptionOrNull()

        assertThat(failure).isNotNull()
        assertThat(dao.findAttendee(5, "VG-TX-88")).isNull()
        assertThat(dao.loadSyncMetadata(5)).isNull()
    }

    @Test
    fun upsertAttendeesAndSyncMetadataDoesNotWriteMetadataWhenAttendeeWriteFails() = runTest {
        createAbortInsertTrigger(
            tableName = "attendees",
            triggerName = "abort_attendees_insert"
        )

        val failure =
            runCatching {
                dao.upsertAttendeesAndSyncMetadata(
                    attendees =
                        listOf(
                            AttendeeEntity(
                                id = 89,
                                eventId = 5,
                                ticketCode = "VG-TX-89",
                                firstName = "Fail",
                                lastName = "Attendee",
                                email = "fail-attendee@example.com",
                                ticketType = "General",
                                allowedCheckins = 1,
                                checkinsRemaining = 1,
                                paymentStatus = "completed",
                                isCurrentlyInside = false,
                                checkedInAt = null,
                                checkedOutAt = null,
                                updatedAt = "2026-03-13T10:04:00Z"
                            )
                        ),
                    metadata =
                        SyncMetadataEntity(
                            eventId = 5,
                            lastServerTime = "2026-03-13T10:05:00Z",
                            lastSuccessfulSyncAt = "2026-03-13T10:05:00Z",
                            lastSyncType = "full",
                            attendeeCount = 1
                        )
                )
            }.exceptionOrNull()

        assertThat(failure).isNotNull()
        assertThat(dao.findAttendee(5, "VG-TX-89")).isNull()
        assertThat(dao.loadSyncMetadata(5)).isNull()
    }

    @Test
    fun unresolvedEventIdsIncludeQueuedScansAndActiveOverlays() = runTest {
        dao.insertQueuedScan(
            QueuedScanEntity(
                eventId = 7,
                ticketCode = "VG-700",
                idempotencyKey = "idem-700",
                createdAt = 700L,
                scannedAt = "2026-03-13T10:06:00Z",
                entranceName = "Main",
                operatorName = "Op"
            )
        )
        dao.upsertLocalAdmissionOverlay(
            LocalAdmissionOverlayEntity(
                eventId = 8,
                attendeeId = 80L,
                ticketCode = "VG-800",
                idempotencyKey = "idem-800",
                state = LocalAdmissionOverlayState.CONFIRMED_LOCAL_UNSYNCED.name,
                createdAtEpochMillis = 800L,
                overlayScannedAt = "2026-03-13T10:07:00Z",
                expectedRemainingAfterOverlay = 0,
                operatorName = "Op",
                entranceName = "Side"
            )
        )

        assertThat(dao.loadUnresolvedEventIdsExcluding(9L)).containsExactly(7L, 8L).inOrder()
        assertThat(dao.loadUnresolvedEventIdsExcluding(8L)).containsExactly(7L)
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

    private fun writableDatabase(): SupportSQLiteDatabase = database.openHelper.writableDatabase
}
