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
import za.co.voelgoed.fastcheck.data.local.AttendeeEntity
import za.co.voelgoed.fastcheck.data.local.LatestFlushSnapshotEntity
import za.co.voelgoed.fastcheck.data.local.LocalAdmissionOverlayEntity
import za.co.voelgoed.fastcheck.data.local.LocalReplaySuppressionEntity
import za.co.voelgoed.fastcheck.data.local.QueuedScanEntity
import za.co.voelgoed.fastcheck.data.local.QuarantinedScanEntity
import za.co.voelgoed.fastcheck.data.local.RecentFlushOutcomeEntity
import za.co.voelgoed.fastcheck.data.local.ReplayCacheEntity
import za.co.voelgoed.fastcheck.data.local.SyncMetadataEntity

@RunWith(RobolectricTestRunner::class)
class LocalRuntimeDataCleanerTest {
    private lateinit var database: FastCheckDatabase
    private lateinit var cleaner: LocalRuntimeDataCleaner

    @Before
    fun setUp() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        database =
            Room.inMemoryDatabaseBuilder(context, FastCheckDatabase::class.java)
                .allowMainThreadQueries()
                .build()
        cleaner = DefaultLocalRuntimeDataCleaner(database.scannerDao())
    }

    @After
    fun tearDown() {
        database.close()
    }

    @Test
    fun explicitLogoutClearsNonDurableRuntimeStateAndPreservesQueueOverlayAndQuarantine() = runTest {
        seedRuntimeRows(eventId = 5L)

        cleaner.handleExplicitLogout(currentEventId = 5L)

        val dao = database.scannerDao()
        assertThat(dao.findAttendee(5L, "VG-5")).isNull()
        assertThat(dao.loadSyncMetadata(5L)).isNull()
        assertThat(dao.findReplaySuppression("VG-5")).isNull()
        assertThat(dao.findReplayCache("idem-replay-5")).isNull()
        assertThat(dao.loadLatestFlushSnapshot()).isNull()
        assertThat(dao.loadRecentFlushOutcomes()).isEmpty()
        assertThat(dao.loadQueuedScans()).hasSize(1)
        assertThat(dao.loadActiveOverlaysForEvent(5L)).hasSize(1)
        assertThat(dao.countQuarantinedScans()).isEqualTo(1)
    }

    @Test
    fun authExpiryPreservesRecoveryStateAndDurableRows() = runTest {
        seedRuntimeRows(eventId = 5L)

        cleaner.handleAuthExpired(currentEventId = 5L)

        val dao = database.scannerDao()
        assertThat(dao.findAttendee(5L, "VG-5")).isNotNull()
        assertThat(dao.loadSyncMetadata(5L)).isNotNull()
        assertThat(dao.findReplaySuppression("VG-5")).isNull()
        assertThat(dao.findReplayCache("idem-replay-5")).isNotNull()
        assertThat(dao.loadLatestFlushSnapshot()).isNotNull()
        assertThat(dao.loadRecentFlushOutcomes()).isNotEmpty()
        assertThat(dao.loadQueuedScans()).hasSize(1)
        assertThat(dao.loadActiveOverlaysForEvent(5L)).hasSize(1)
        assertThat(dao.countQuarantinedScans()).isEqualTo(1)
    }

    @Test
    fun cleanEventTransitionClearsOnlyPriorEventCacheAndSync() = runTest {
        seedRuntimeRows(eventId = 5L)
        seedRuntimeRows(eventId = 7L)

        cleaner.handleCleanEventTransition(fromEventId = 5L, toEventId = 7L)

        val dao = database.scannerDao()
        assertThat(dao.findAttendee(5L, "VG-5")).isNull()
        assertThat(dao.loadSyncMetadata(5L)).isNull()
        assertThat(dao.findAttendee(7L, "VG-7")).isNotNull()
        assertThat(dao.loadSyncMetadata(7L)).isNotNull()
        assertThat(dao.loadQueuedScans()).hasSize(2)
        assertThat(dao.countQuarantinedScans()).isEqualTo(2)
    }

    private suspend fun seedRuntimeRows(eventId: Long) {
        val dao = database.scannerDao()
        dao.upsertAttendees(
            listOf(
                AttendeeEntity(
                    id = eventId,
                    eventId = eventId,
                    ticketCode = "VG-$eventId",
                    firstName = "First",
                    lastName = "Last",
                    email = "person-$eventId@example.com",
                    ticketType = "General",
                    allowedCheckins = 1,
                    checkinsRemaining = 1,
                    paymentStatus = "completed",
                    isCurrentlyInside = false,
                    checkedInAt = null,
                    checkedOutAt = null,
                    updatedAt = "2026-04-07T10:00:00Z"
                )
            )
        )
        dao.upsertSyncMetadata(
            SyncMetadataEntity(
                eventId = eventId,
                lastServerTime = "2026-04-07T10:00:00Z",
                lastSuccessfulSyncAt = "2026-04-07T10:00:00Z",
                lastSyncType = "full",
                attendeeCount = 1
            )
        )
        dao.insertQueuedScan(
            QueuedScanEntity(
                eventId = eventId,
                ticketCode = "VG-$eventId",
                idempotencyKey = "idem-queue-$eventId",
                createdAt = eventId,
                scannedAt = "2026-04-07T10:00:00Z",
                entranceName = "Main",
                operatorName = "Op"
            )
        )
        dao.upsertLocalAdmissionOverlay(
            LocalAdmissionOverlayEntity(
                eventId = eventId,
                attendeeId = eventId,
                ticketCode = "VG-$eventId",
                idempotencyKey = "idem-overlay-$eventId",
                state = "PENDING_LOCAL",
                createdAtEpochMillis = eventId,
                overlayScannedAt = "2026-04-07T10:00:00Z",
                expectedRemainingAfterOverlay = 0,
                operatorName = "Op",
                entranceName = "Main"
            )
        )
        dao.insertQuarantinedScans(
            listOf(
                QuarantinedScanEntity(
                    originalQueueId = null,
                    createdAt = eventId,
                    scannedAt = "2026-04-07T10:00:00Z",
                    direction = "in",
                    entranceName = "Main",
                    operatorName = "Op",
                    lastAttemptAt = null,
                    quarantineReason = "duplicate_capture",
                    quarantineMessage = "duplicate_capture",
                    batchAttributed = false,
                    overlayStateAtQuarantine = "PENDING_LOCAL",
                    idempotencyKey = "idem-quarantine-$eventId",
                    eventId = eventId,
                    ticketCode = "VG-$eventId",
                    quarantinedAt = "2026-04-07T10:00:00Z",
                )
            )
        )
        dao.upsertReplaySuppression(
            LocalReplaySuppressionEntity(
                id = 0,
                ticketCode = "VG-$eventId",
                seenAtEpochMillis = eventId
            )
        )
        dao.upsertReplayCache(
            ReplayCacheEntity(
                idempotencyKey = "idem-replay-$eventId",
                status = "success",
                message = "ok",
                reasonCode = null,
                storedAt = "2026-04-07T10:00:00Z",
                terminal = true
            )
        )
        dao.upsertLatestFlushSnapshot(
            LatestFlushSnapshotEntity(
                executionStatus = "COMPLETED",
                uploadedCount = 1,
                retryableRemainingCount = 0,
                authExpired = false,
                backlogRemaining = false,
                summaryMessage = "done",
                completedAt = "2026-04-07T10:00:00Z"
            )
        )
        dao.insertRecentFlushOutcomes(
            listOf(
                RecentFlushOutcomeEntity(
                    outcomeOrder = 0,
                    idempotencyKey = "idem-replay-$eventId",
                    ticketCode = "VG-$eventId",
                    outcome = "SUCCESS",
                    message = "ok",
                    reasonCode = null,
                    completedAt = "2026-04-07T10:00:00Z"
                )
            )
        )
    }
}
