package za.co.voelgoed.fastcheck.data.local

import android.content.Context
import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import com.google.common.truth.Truth.assertThat
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import za.co.voelgoed.fastcheck.core.database.FastCheckDatabase
import za.co.voelgoed.fastcheck.core.database.FastCheckDatabaseInvariantCallback
import za.co.voelgoed.fastcheck.data.repository.DefaultEventBucketRepository
import java.time.Clock
import java.time.Instant
import java.time.ZoneOffset

@RunWith(RobolectricTestRunner::class)
class ScannerDaoEventIsolationTest {
    private lateinit var database: FastCheckDatabase
    private lateinit var dao: ScannerDao

    @Before
    fun setUp() {
        database =
            Room.inMemoryDatabaseBuilder(
                ApplicationProvider.getApplicationContext<Context>(),
                FastCheckDatabase::class.java
            ).addCallback(FastCheckDatabaseInvariantCallback).allowMainThreadQueries().build()
        dao = database.scannerDao()
    }

    @After
    fun tearDown() = database.close()

    @Test
    fun queueAndQuarantineReadsAreScopedToEvent() = runTest {
        dao.insertQueuedScan(scan(eventId = 10L, key = "a-1", createdAt = 20L))
        dao.insertQueuedScan(scan(eventId = 20L, key = "b-1", createdAt = 10L))
        dao.insertQueuedScan(scan(eventId = 10L, key = "a-2", createdAt = 5L))

        assertThat(dao.loadQueuedScansForEvent(10L, 50).map { it.idempotencyKey })
            .containsExactly("a-2", "a-1")
            .inOrder()
        assertThat(dao.countPendingScansForEvent(10L)).isEqualTo(2)
        assertThat(dao.observePendingScanCountForEvent(20L).first()).isEqualTo(1)
        assertThat(dao.countQuarantinedScansForEvent(10L)).isEqualTo(0)
    }

    @Test
    fun replaySuppressionUsesEventAndTicketCompositeIdentity() = runTest {
        dao.upsertReplaySuppression(LocalReplaySuppressionEntity(10L, "SAME", 100L))
        dao.upsertReplaySuppression(LocalReplaySuppressionEntity(20L, "SAME", 200L))

        assertThat(dao.findReplaySuppression(10L, "SAME")?.seenAtEpochMillis).isEqualTo(100L)
        assertThat(dao.findReplaySuppression(20L, "SAME")?.seenAtEpochMillis).isEqualTo(200L)
    }

    @Test
    fun flushStateReplacementDoesNotClearAnotherEvent() = runTest {
        dao.replaceLatestFlushState(10L, snapshot(10L, "A"), listOf(outcome(10L, "a")))
        dao.replaceLatestFlushState(20L, snapshot(20L, "B"), listOf(outcome(20L, "b")))

        assertThat(dao.loadLatestFlushSnapshot(10L)?.summaryMessage).isEqualTo("A")
        assertThat(dao.loadRecentFlushOutcomes(10L).single().idempotencyKey).isEqualTo("a")
        assertThat(dao.loadLatestFlushSnapshot(20L)?.summaryMessage).isEqualTo("B")
        assertThat(dao.loadRecentFlushOutcomes(20L).single().idempotencyKey).isEqualTo("b")
    }

    @Test
    fun sqliteInvariantRejectsSecondActiveBucket() = runTest {
        val cursor = database.openHelper.writableDatabase.query("PRAGMA index_list(event_local_buckets)")
        val names = buildList {
            cursor.use { while (it.moveToNext()) add(it.getString(it.getColumnIndexOrThrow("name"))) }
        }
        assertThat(names).contains("index_event_local_buckets_single_active")
        dao.upsertEventLocalBucket(bucket(10, EventLocalBucketState.ACTIVE, 10))
        val failure = runCatching {
            database.openHelper.writableDatabase.execSQL(
                "INSERT INTO event_local_buckets SELECT 20, eventName, eventShortname, state, " +
                    "selectedAtEpochMillis, lastActivatedAtEpochMillis, closeRequestedAtEpochMillis, " +
                    "lastFlushAttemptAtEpochMillis, lastSuccessfulFlushAtEpochMillis, " +
                    "lastSuccessfulReconcileAtEpochMillis, pendingScanCountSnapshot, " +
                    "activeOverlayCountSnapshot, awaitingReconciliationCountSnapshot, conflictCountSnapshot, " +
                    "quarantinedScanCountSnapshot, lastErrorCode, lastErrorMessage, updatedAtEpochMillis " +
                    "FROM event_local_buckets WHERE eventId = 10"
            )
        }
        assertThat(failure.isFailure).isTrue()
    }

    @Test
    fun bucketObservationUsesDeterministicOperationalPriority() = runTest {
        dao.upsertEventLocalBucket(bucket(50, EventLocalBucketState.PARKED, 50))
        dao.upsertEventLocalBucket(bucket(40, EventLocalBucketState.PARKED, 40).copy(pendingScanCountSnapshot = 2))
        dao.upsertEventLocalBucket(bucket(30, EventLocalBucketState.PARKED, 30).copy(conflictCountSnapshot = 1))
        dao.upsertEventLocalBucket(bucket(20, EventLocalBucketState.AUTH_REQUIRED, 20).copy(quarantinedScanCountSnapshot = 1))
        dao.upsertEventLocalBucket(bucket(10, EventLocalBucketState.ACTIVE, 10))
        assertThat(dao.observeAllEventLocalBuckets().first().map { it.eventId })
            .containsExactly(10L, 20L, 30L, 40L, 50L).inOrder()
    }

    @Test
    fun switchingAwayAndBackRetainsEventAttendeeCache() = runTest {
        val buckets = DefaultEventBucketRepository(
            database,
            Clock.fixed(Instant.parse("2026-08-03T10:00:00Z"), ZoneOffset.UTC)
        )
        val attendee = AttendeeEntity(
            501, 10, "A-501", "Ada", "Operator", null, "VIP", 1, 1,
            "completed", false, null, null, "2026-08-03T09:00:00Z"
        )
        dao.upsertAttendees(listOf(attendee))

        buckets.activate(10, "Event A", "A")
        buckets.activate(20, "Event B", "B")
        buckets.activate(10, "Event A", "A")

        assertThat(dao.findAttendee(10, "A-501")).isEqualTo(attendee)
        assertThat(dao.loadEventLocalBucketsByState(EventLocalBucketState.ACTIVE).map { it.eventId })
            .containsExactly(10L)
    }

    @Test
    fun syncMetadataObserverReturnsOnlyRequestedEvent() = runTest {
        dao.upsertSyncMetadata(syncMetadata(10L, "2026-08-03T09:00:00Z"))
        dao.upsertSyncMetadata(syncMetadata(20L, "2026-08-03T10:00:00Z"))

        assertThat(dao.observeSyncMetadataForEvent(10L).first()?.eventId).isEqualTo(10L)
        assertThat(dao.observeSyncMetadataForEvent(10L).first()?.lastSuccessfulSyncAt)
            .isEqualTo("2026-08-03T09:00:00Z")
    }

    private fun bucket(eventId: Long, state: String, updatedAt: Long) = EventLocalBucketEntity(
        eventId = eventId, state = state, selectedAtEpochMillis = updatedAt,
        lastActivatedAtEpochMillis = updatedAt, closeRequestedAtEpochMillis = null,
        lastFlushAttemptAtEpochMillis = null, lastSuccessfulFlushAtEpochMillis = null,
        lastSuccessfulReconcileAtEpochMillis = null, pendingScanCountSnapshot = 0,
        activeOverlayCountSnapshot = 0, quarantinedScanCountSnapshot = 0,
        lastErrorCode = null, lastErrorMessage = null, updatedAtEpochMillis = updatedAt
    )

    private fun scan(eventId: Long, key: String, createdAt: Long) =
        QueuedScanEntity(
            eventId = eventId,
            ticketCode = key,
            idempotencyKey = key,
            createdAt = createdAt,
            scannedAt = "2026-01-01T00:00:00Z",
            entranceName = "Main",
            operatorName = "Operator"
        )

    private fun snapshot(eventId: Long, message: String) =
        LatestFlushSnapshotEntity(
            eventId = eventId,
            executionStatus = "COMPLETED",
            uploadedCount = 1,
            retryableRemainingCount = 0,
            authExpired = false,
            backlogRemaining = false,
            summaryMessage = message,
            completedAt = "2026-01-01T00:00:00Z"
        )

    private fun outcome(eventId: Long, key: String) =
        RecentFlushOutcomeEntity(
            eventId = eventId,
            outcomeOrder = 0,
            idempotencyKey = key,
            ticketCode = key,
            outcome = "SUCCESS",
            message = "ok",
            completedAt = "2026-01-01T00:00:00Z"
        )

    private fun syncMetadata(eventId: Long, syncedAt: String) = SyncMetadataEntity(
        eventId = eventId,
        lastServerTime = syncedAt,
        lastSuccessfulSyncAt = syncedAt,
        lastSyncType = "incremental",
        attendeeCount = 1
    )
}
