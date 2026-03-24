package za.co.voelgoed.fastcheck.data.local

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
                        reasonCode = null,
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
    }
}
