package za.co.voelgoed.fastcheck.core.database

import android.content.Context
import android.database.Cursor
import android.database.sqlite.SQLiteDatabase
import androidx.room.Room
import androidx.sqlite.db.SupportSQLiteDatabase
import androidx.test.core.app.ApplicationProvider
import com.google.common.truth.Truth.assertThat
import java.io.File
import java.time.Clock
import java.time.Instant
import java.time.ZoneOffset
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import retrofit2.Response
import za.co.voelgoed.fastcheck.core.network.PhoenixMobileApi
import za.co.voelgoed.fastcheck.core.session.AuthenticatedEventContext
import za.co.voelgoed.fastcheck.core.session.AuthenticatedEventContextStore
import za.co.voelgoed.fastcheck.core.concurrency.DefaultEventOperationMutexRegistry
import za.co.voelgoed.fastcheck.data.repository.NoOpEventBucketRepository
import za.co.voelgoed.fastcheck.data.local.LatestFlushSnapshotEntity
import za.co.voelgoed.fastcheck.data.local.RecentFlushOutcomeEntity
import za.co.voelgoed.fastcheck.data.remote.MobileLoginRequest
import za.co.voelgoed.fastcheck.data.remote.MobileLoginResponse
import za.co.voelgoed.fastcheck.data.remote.MobileSyncResponse
import za.co.voelgoed.fastcheck.data.remote.PhoenixMobileRemoteDataSource
import za.co.voelgoed.fastcheck.data.remote.UploadScansPayload
import za.co.voelgoed.fastcheck.data.remote.UploadScansRequest
import za.co.voelgoed.fastcheck.data.remote.UploadScansResponse
import za.co.voelgoed.fastcheck.data.remote.UploadedScanResult
import za.co.voelgoed.fastcheck.data.repository.CurrentPhoenixMobileScanRepository
import za.co.voelgoed.fastcheck.data.repository.FlushResultClassifier

@RunWith(RobolectricTestRunner::class)
class FastCheckDatabaseMigrationTest {
    private lateinit var context: Context
    private lateinit var databaseFile: File

    @Before
    fun setUp() {
        context = ApplicationProvider.getApplicationContext()
        databaseFile = context.getDatabasePath("fastcheck-migration-test.db")
        if (databaseFile.exists()) {
            databaseFile.delete()
        }
        databaseFile.parentFile?.mkdirs()
    }

    @After
    fun tearDown() {
        if (databaseFile.exists()) {
            databaseFile.delete()
        }
    }


    @Test
    fun migratesVersion3To11AddsEventLocalBucketsTableWithoutMutatingQueueRows() = runTest {
        createVersion3Schema(databaseFile)

        val database =
            Room.databaseBuilder(context, FastCheckDatabase::class.java, databaseFile.absolutePath)
                .addMigrations(
                    FastCheckDatabaseMigrations.MIGRATION_3_4,
                    FastCheckDatabaseMigrations.MIGRATION_4_5,
                    FastCheckDatabaseMigrations.MIGRATION_5_6,
                    FastCheckDatabaseMigrations.MIGRATION_6_7,
                    FastCheckDatabaseMigrations.MIGRATION_7_8,
                    FastCheckDatabaseMigrations.MIGRATION_8_9,
                    FastCheckDatabaseMigrations.MIGRATION_9_10,
                    FastCheckDatabaseMigrations.MIGRATION_10_11,
                    FastCheckDatabaseMigrations.MIGRATION_11_12
                )
                .allowMainThreadQueries()
                .build()

        val sqliteDb = database.openHelper.writableDatabase
        val queued = database.scannerDao().loadQueuedScans()

        assertThat(queued.map { it.ticketCode }).containsExactly("VG-100", "VG-200").inOrder()
        assertTableExists(sqliteDb, "event_local_buckets")
        assertIndexColumns(sqliteDb = sqliteDb, indexName = "index_event_local_buckets_state", expectedColumns = listOf("state"), tableName = "event_local_buckets")
        assertIndexColumns(
            sqliteDb = sqliteDb,
            indexName = "index_event_local_buckets_lastFlushAttemptAtEpochMillis",
            expectedColumns = listOf("lastFlushAttemptAtEpochMillis"),
            tableName = "event_local_buckets"
        )

        database.close()
    }

    @Test
    fun migration11To12PreservesCompleteDurableEvidenceAndClearsOnlyUnattributedEphemeralRows() = runTest {
        createVersion11SchemaWithDurableEvidence(databaseFile)
        val database = Room.databaseBuilder(context, FastCheckDatabase::class.java, databaseFile.absolutePath)
            .addMigrations(FastCheckDatabaseMigrations.MIGRATION_11_12)
            .addCallback(FastCheckDatabaseInvariantCallback)
            .allowMainThreadQueries()
            .build()
        val dao = database.scannerDao()

        assertThat(dao.loadQueuedScansForEvent(41L, 10).single()).isEqualTo(
            za.co.voelgoed.fastcheck.data.local.QueuedScanEntity(
                id = 101, eventId = 41, ticketCode = "Q-41", idempotencyKey = "queue-41",
                createdAt = 1234, scannedAt = "2026-08-03T09:00:00Z", direction = "in",
                entranceName = "North", operatorName = "Operator", replayed = false,
                lastAttemptAt = "2026-08-03T09:01:00Z"
            )
        )
        assertThat(dao.findAttendee(41L, "T-41")).isEqualTo(
            za.co.voelgoed.fastcheck.data.local.AttendeeEntity(
                201, 41, "T-41", "Ada", "Lovelace", "ada@example.test", "VIP",
                2, 1, "completed", true, "2026-08-03T08:00:00Z", null,
                "2026-08-03T08:30:00Z"
            )
        )
        assertThat(dao.loadActiveOverlaysForEvent(41L).single()).isEqualTo(
            za.co.voelgoed.fastcheck.data.local.LocalAdmissionOverlayEntity(
                301, 41, 201, "T-41", "overlay-41", "in", "CONFLICT_REJECTED", 1300,
                "2026-08-03T09:00:01Z", 0, "Operator", "North", "capacity", "Full"
            )
        )
        assertThat(dao.loadLatestQuarantinedScanForEvent(41L)).isEqualTo(
            za.co.voelgoed.fastcheck.data.local.QuarantinedScanEntity(
                401, 101, 41, "X-41", "quarantine-41", 1400,
                "2026-08-03T09:00:02Z", "in", "North", "Operator",
                "2026-08-03T09:02:00Z", "contract_error", "Bad response",
                "2026-08-03T09:03:00Z", true, "PENDING_LOCAL"
            )
        )
        assertThat(dao.loadSyncMetadata(41L)).isEqualTo(
            za.co.voelgoed.fastcheck.data.local.SyncMetadataEntity(
                41, "2026-08-03T08:30:00Z", "2026-08-03T08:30:00Z", "incremental", 1,
                "2026-08-03T07:00:00Z", "2026-08-03T08:29:00Z", 2, "timeout",
                "2026-08-03T08:29:30Z", "2026-08-03T07:00:00Z", 3, 4, 5, 6, 7
            )
        )
        assertThat(dao.findReplaySuppression(41L, "T-41")).isNull()
        assertThat(dao.loadLatestFlushSnapshot()).isNull()
        assertThat(dao.loadRecentFlushOutcomes()).isEmpty()
        assertThat(dao.loadEventLocalBucket(41L)?.state).isEqualTo("PARKED")
        assertThat(dao.loadEventLocalBucket(41L)?.pendingScanCountSnapshot).isEqualTo(1)
        assertThat(dao.loadEventLocalBucket(41L)?.conflictCountSnapshot).isEqualTo(1)
        assertThat(dao.loadEventLocalBucket(41L)?.quarantinedScanCountSnapshot).isEqualTo(1)
        assertIndexColumns(
            database.openHelper.writableDatabase,
            "index_event_local_buckets_single_active",
            listOf("state"),
            "event_local_buckets"
        )
        database.close()
    }

    @Test
    fun migratesVersion2PreservingReplayCacheAndClearingUnattributedFlushDisplayRows() = runTest {
        createVersion2Schema(databaseFile)

        val database =
            Room.databaseBuilder(context, FastCheckDatabase::class.java, databaseFile.absolutePath)
                .addMigrations(
                    FastCheckDatabaseMigrations.MIGRATION_2_3,
                    FastCheckDatabaseMigrations.MIGRATION_3_4,
                    FastCheckDatabaseMigrations.MIGRATION_4_5,
                    FastCheckDatabaseMigrations.MIGRATION_5_6,
                    FastCheckDatabaseMigrations.MIGRATION_6_7,
                    FastCheckDatabaseMigrations.MIGRATION_7_8,
                    FastCheckDatabaseMigrations.MIGRATION_8_9,
                    FastCheckDatabaseMigrations.MIGRATION_9_10,
                    FastCheckDatabaseMigrations.MIGRATION_10_11,
                    FastCheckDatabaseMigrations.MIGRATION_11_12
                )
                .allowMainThreadQueries()
                .build()
        val sqliteDb = database.openHelper.writableDatabase
        val replayCache = database.scannerDao().findReplayCache("idem-cache")
        val outcomes = database.scannerDao().loadRecentFlushOutcomes(limit = 5)

        assertNullableReasonCodeColumn(sqliteDb.query("PRAGMA table_info(recent_flush_outcomes)"), "reasonCode")
        assertNullableReasonCodeColumn(sqliteDb.query("PRAGMA table_info(scan_replay_cache)"), "reasonCode")
        assertIndexColumns(
            sqliteDb = sqliteDb,
            indexName = "index_queued_scans_replayed_createdAt_id",
            expectedColumns = listOf("replayed", "createdAt", "id")
        )

        assertThat(replayCache).isNotNull()
        assertThat(replayCache?.message).isEqualTo("Already checked in")
        assertThat(replayCache?.reasonCode).isNull()
        assertThat(outcomes).isEmpty()

        database.scannerDao().replaceLatestFlushState(
            snapshot =
                LatestFlushSnapshotEntity(
                    eventId = 5L,
                    executionStatus = "COMPLETED",
                    uploadedCount = 2,
                    retryableRemainingCount = 0,
                    authExpired = false,
                    backlogRemaining = false,
                    summaryMessage = "Migrated flush completed.",
                    completedAt = "2026-03-24T06:05:00Z"
                ),
            outcomes =
                listOf(
                    RecentFlushOutcomeEntity(
                        eventId = 5L,
                        outcomeOrder = 0,
                        idempotencyKey = "idem-new-1",
                        ticketCode = "VG-010",
                        outcome = "DUPLICATE",
                        message = "Already processed",
                        reasonCode = "business_duplicate",
                        completedAt = "2026-03-24T06:05:00Z"
                    ),
                    RecentFlushOutcomeEntity(
                        eventId = 5L,
                        outcomeOrder = 1,
                        idempotencyKey = "idem-new-2",
                        ticketCode = "VG-011",
                        outcome = "TERMINAL_ERROR",
                        message = "Payment invalid",
                        reasonCode = "payment_invalid",
                        completedAt = "2026-03-24T06:05:00Z"
                    )
                )
        )

        val replacedOutcomes = database.scannerDao().loadRecentFlushOutcomes(limit = 5)

        assertThat(replacedOutcomes.map { it.ticketCode }).containsExactly("VG-010", "VG-011").inOrder()
        assertThat(replacedOutcomes.map { it.reasonCode })
            .containsExactly("business_duplicate", "payment_invalid")
            .inOrder()

        database.close()
    }

    @Test
    fun migratesVersion3QueuedScansAddsPendingQueueIndexAndPreservesPendingQueryBehavior() = runTest {
        createVersion3Schema(databaseFile)

        val database =
            Room.databaseBuilder(context, FastCheckDatabase::class.java, databaseFile.absolutePath)
                .addMigrations(
                    FastCheckDatabaseMigrations.MIGRATION_3_4,
                    FastCheckDatabaseMigrations.MIGRATION_4_5,
                    FastCheckDatabaseMigrations.MIGRATION_5_6,
                    FastCheckDatabaseMigrations.MIGRATION_6_7,
                    FastCheckDatabaseMigrations.MIGRATION_7_8,
                    FastCheckDatabaseMigrations.MIGRATION_8_9,
                    FastCheckDatabaseMigrations.MIGRATION_9_10,
                    FastCheckDatabaseMigrations.MIGRATION_10_11,
                    FastCheckDatabaseMigrations.MIGRATION_11_12
                )
                .allowMainThreadQueries()
                .build()
        val sqliteDb = database.openHelper.writableDatabase

        val queued = database.scannerDao().loadQueuedScans()
        val pendingCount = database.scannerDao().countPendingScans()

        assertThat(queued.map { it.ticketCode }).containsExactly("VG-100", "VG-200").inOrder()
        assertThat(pendingCount).isEqualTo(2)
        assertIndexColumns(
            sqliteDb = sqliteDb,
            indexName = "index_queued_scans_replayed_createdAt_id",
            expectedColumns = listOf("replayed", "createdAt", "id")
        )
        assertIndexColumns(
            sqliteDb = sqliteDb,
            indexName = "index_queued_scans_idempotencyKey",
            expectedColumns = listOf("idempotencyKey")
        )

        database.close()
    }

    @Test
    fun migratesVersion4TicketIdentityDataToCanonicalFormAndFlushesQueue() = runTest {
        createVersion4SchemaWithNormalizationCollisions(databaseFile)

        val database =
            Room.databaseBuilder(context, FastCheckDatabase::class.java, databaseFile.absolutePath)
                .addMigrations(
                    FastCheckDatabaseMigrations.MIGRATION_4_5,
                    FastCheckDatabaseMigrations.MIGRATION_5_6,
                    FastCheckDatabaseMigrations.MIGRATION_6_7,
                    FastCheckDatabaseMigrations.MIGRATION_7_8,
                    FastCheckDatabaseMigrations.MIGRATION_8_9,
                    FastCheckDatabaseMigrations.MIGRATION_9_10,
                    FastCheckDatabaseMigrations.MIGRATION_10_11,
                    FastCheckDatabaseMigrations.MIGRATION_11_12
                )
                .allowMainThreadQueries()
                .build()
        val scannerDao = database.scannerDao()

        val attendee = scannerDao.findAttendee(5, "VG-COLLAPSE")
        val replaySuppression = scannerDao.findReplaySuppression(5L, "VG-COLLAPSE")
        val queuedBeforeFlush = scannerDao.loadQueuedScans()
        val recentOutcomes = scannerDao.loadRecentFlushOutcomes(limit = 5)

        assertThat(attendee?.id).isEqualTo(11L)
        assertThat(scannerDao.findAttendee(5, " VG-COLLAPSE ")).isNull()
        assertThat(replaySuppression).isNull()
        assertThat(scannerDao.findReplaySuppression(5L, " VG-COLLAPSE ")).isNull()
        assertThat(queuedBeforeFlush.single().ticketCode).isEqualTo("VG-QUEUE-1")
        assertThat(recentOutcomes).isEmpty()

        val api = RecordingPhoenixMobileApi()
        val repository =
            CurrentPhoenixMobileScanRepository(
                scannerDao = scannerDao,
                remoteDataSource = PhoenixMobileRemoteDataSource(api),
                flushResultClassifier = FlushResultClassifier(),
                clock = Clock.fixed(Instant.parse("2026-03-24T14:30:00Z"), ZoneOffset.UTC),
                contextStore = object : AuthenticatedEventContextStore {
                    private val value = AuthenticatedEventContext(5, "migration-test-token", 1, 0, Long.MAX_VALUE)
                    override suspend fun capture() = value
                    override suspend fun currentIdentity() = value.identity
                    override suspend fun replace(eventId: Long, bearerToken: String, authenticatedAtEpochMillis: Long, expiresAtEpochMillis: Long) = error("unused")
                    override suspend fun clearIfGenerationMatches(sessionGeneration: Long) = false
                    override suspend fun isCurrent(sessionGeneration: Long) = sessionGeneration == 1L
                    override fun observeIdentity() = kotlinx.coroutines.flow.flowOf(value.identity)
                },
                operationMutexRegistry = DefaultEventOperationMutexRegistry(),
                eventBucketRepository = NoOpEventBucketRepository
            )

        val flushReport = (repository.flushQueuedScans(maxBatchSize = 10) as za.co.voelgoed.fastcheck.data.repository.FlushInvocationResult.Attempted).report

        assertThat(flushReport.uploadedCount).isEqualTo(1)
        assertThat(api.lastUploadBody?.scans?.single()?.ticket_code).isEqualTo("VG-QUEUE-1")
        assertThat(scannerDao.countPendingScans()).isEqualTo(0)

        database.close()
    }

    @Test
    fun chainedMigrationFromVersion3To5CollapsesIndexedTicketDuplicatesSafely() = runTest {
        createVersion3SchemaWithNormalizationCollisions(databaseFile)

        val database =
            Room.databaseBuilder(context, FastCheckDatabase::class.java, databaseFile.absolutePath)
                .addMigrations(
                    FastCheckDatabaseMigrations.MIGRATION_3_4,
                    FastCheckDatabaseMigrations.MIGRATION_4_5,
                    FastCheckDatabaseMigrations.MIGRATION_5_6,
                    FastCheckDatabaseMigrations.MIGRATION_6_7,
                    FastCheckDatabaseMigrations.MIGRATION_7_8,
                    FastCheckDatabaseMigrations.MIGRATION_8_9,
                    FastCheckDatabaseMigrations.MIGRATION_9_10,
                    FastCheckDatabaseMigrations.MIGRATION_10_11,
                    FastCheckDatabaseMigrations.MIGRATION_11_12
                )
                .allowMainThreadQueries()
                .build()
        val scannerDao = database.scannerDao()

        assertThat(scannerDao.findAttendee(5, "VG-V3-COLLAPSE")?.id).isEqualTo(31L)
        assertThat(scannerDao.findReplaySuppression(5L, "VG-V3-COLLAPSE")).isNull()
        assertThat(scannerDao.loadQueuedScans().map { it.ticketCode }).contains("VG-V3-QUEUE")

        database.close()
    }

    @Test
    fun version2To5MigrationCanonicalizesTicketIdentity() = runTest {
        createVersion2SchemaWithNormalizationCollisions(databaseFile)

        val database =
            Room.databaseBuilder(context, FastCheckDatabase::class.java, databaseFile.absolutePath)
                .addMigrations(
                    FastCheckDatabaseMigrations.MIGRATION_2_3,
                    FastCheckDatabaseMigrations.MIGRATION_3_4,
                    FastCheckDatabaseMigrations.MIGRATION_4_5,
                    FastCheckDatabaseMigrations.MIGRATION_5_6,
                    FastCheckDatabaseMigrations.MIGRATION_6_7,
                    FastCheckDatabaseMigrations.MIGRATION_7_8,
                    FastCheckDatabaseMigrations.MIGRATION_8_9,
                    FastCheckDatabaseMigrations.MIGRATION_9_10,
                    FastCheckDatabaseMigrations.MIGRATION_10_11,
                    FastCheckDatabaseMigrations.MIGRATION_11_12
                )
                .allowMainThreadQueries()
                .build()
        val sqliteDb = database.openHelper.writableDatabase
        val scannerDao = database.scannerDao()

        assertNullableReasonCodeColumn(sqliteDb.query("PRAGMA table_info(recent_flush_outcomes)"), "reasonCode")
        assertNullableReasonCodeColumn(sqliteDb.query("PRAGMA table_info(scan_replay_cache)"), "reasonCode")
        assertThat(scannerDao.findAttendee(5, "VG-V2-COLLAPSE")?.id).isEqualTo(41L)
        assertThat(scannerDao.findReplaySuppression(5L, "VG-V2-COLLAPSE")).isNull()
        assertThat(scannerDao.loadQueuedScans().single().ticketCode).isEqualTo("VG-V2-QUEUE")
        assertThat(scannerDao.loadRecentFlushOutcomes(limit = 5)).isEmpty()

        database.close()
    }

    @Test
    fun migratesVersion5AttendeesAddsAttendanceTimestampColumns() = runTest {
        createVersion5Schema(databaseFile)

        val database =
            Room.databaseBuilder(context, FastCheckDatabase::class.java, databaseFile.absolutePath)
                .addMigrations(
                    FastCheckDatabaseMigrations.MIGRATION_5_6,
                    FastCheckDatabaseMigrations.MIGRATION_6_7,
                    FastCheckDatabaseMigrations.MIGRATION_7_8,
                    FastCheckDatabaseMigrations.MIGRATION_8_9,
                    FastCheckDatabaseMigrations.MIGRATION_9_10,
                    FastCheckDatabaseMigrations.MIGRATION_10_11,
                    FastCheckDatabaseMigrations.MIGRATION_11_12
                )
                .allowMainThreadQueries()
                .build()
        val scannerDao = database.scannerDao()
        val sqliteDb = database.openHelper.writableDatabase

        val attendee = scannerDao.findAttendee(5, "VG-V5-001")

        assertThat(attendee).isNotNull()
        assertThat(attendee?.checkedInAt).isNull()
        assertThat(attendee?.checkedOutAt).isNull()
        assertThat(hasColumn(sqliteDb, "attendees", "checkedInAt")).isTrue()
        assertThat(hasColumn(sqliteDb, "attendees", "checkedOutAt")).isTrue()

        database.close()
    }

    @Test
    fun migratesVersion6AddsLocalAdmissionOverlayTableAndIndexes() = runTest {
        createVersion6Schema(databaseFile)

        val database =
            Room.databaseBuilder(context, FastCheckDatabase::class.java, databaseFile.absolutePath)
                .addMigrations(
                    FastCheckDatabaseMigrations.MIGRATION_5_6,
                    FastCheckDatabaseMigrations.MIGRATION_6_7,
                    FastCheckDatabaseMigrations.MIGRATION_7_8,
                    FastCheckDatabaseMigrations.MIGRATION_8_9,
                    FastCheckDatabaseMigrations.MIGRATION_9_10,
                    FastCheckDatabaseMigrations.MIGRATION_10_11,
                    FastCheckDatabaseMigrations.MIGRATION_11_12
                )
                .allowMainThreadQueries()
                .build()
        val sqliteDb = database.openHelper.writableDatabase

        assertThat(hasColumn(sqliteDb, "local_admission_overlays", "overlayScannedAt")).isTrue()
        assertThat(hasColumn(sqliteDb, "local_admission_overlays", "expectedRemainingAfterOverlay")).isTrue()
        assertIndexColumns(
            sqliteDb = sqliteDb,
            indexName = "index_local_admission_overlays_eventId_state",
            expectedColumns = listOf("eventId", "state"),
            tableName = "local_admission_overlays"
        )

        sqliteDb.execSQL(
            """
            INSERT INTO local_admission_overlays (
                eventId, attendeeId, ticketCode, idempotencyKey, direction, state,
                createdAtEpochMillis, overlayScannedAt, expectedRemainingAfterOverlay,
                operatorName, entranceName, conflictReasonCode, conflictMessage
            ) VALUES
                (5, 1001, 'VG-OL-1', 'idem-overlay-1', 'in', 'PENDING_LOCAL', 1000, '2026-03-20T10:00:00Z', 0, 'Scanner 1', 'Main', NULL, NULL),
                (5, 1002, 'VG-OL-2', 'idem-overlay-2', 'in', 'PENDING_LOCAL', 2000, '2026-03-20T10:00:01Z', 0, 'Scanner 1', 'Main', NULL, NULL)
            """.trimIndent()
        )

        val overlayCountForEvent =
            sqliteDb.query("SELECT COUNT(*) FROM local_admission_overlays WHERE eventId = 5").use { cursor ->
                cursor.moveToFirst()
                cursor.getInt(0)
            }

        assertThat(overlayCountForEvent).isEqualTo(2)

        database.close()
    }

    @Test
    fun migratesVersion7To8AddsQuarantineTableEmpty() = runTest {
        createVersion6Schema(databaseFile)

        val database =
            Room.databaseBuilder(context, FastCheckDatabase::class.java, databaseFile.absolutePath)
                .addMigrations(
                    FastCheckDatabaseMigrations.MIGRATION_5_6,
                    FastCheckDatabaseMigrations.MIGRATION_6_7,
                    FastCheckDatabaseMigrations.MIGRATION_7_8,
                    FastCheckDatabaseMigrations.MIGRATION_8_9,
                    FastCheckDatabaseMigrations.MIGRATION_9_10,
                    FastCheckDatabaseMigrations.MIGRATION_10_11,
                    FastCheckDatabaseMigrations.MIGRATION_11_12
                )
                .allowMainThreadQueries()
                .build()
        val sqliteDb = database.openHelper.writableDatabase

        assertThat(hasTable(sqliteDb, "quarantined_scans")).isTrue()
        assertThat(database.scannerDao().countQuarantinedScans()).isEqualTo(0)

        database.close()
    }

    @Test
    fun migration8To9BackfillsLastFullReconcileAtFromLastSuccessfulSyncAt() = runTest {
        createVersion5Schema(databaseFile)
        val seedDb = SQLiteDatabase.openDatabase(databaseFile.absolutePath, null, SQLiteDatabase.OPEN_READWRITE)
        seedDb.execSQL(
            """
            INSERT INTO sync_metadata (eventId, lastServerTime, lastSuccessfulSyncAt, lastSyncType, attendeeCount)
            VALUES (5, '2026-03-28T10:05:00Z', '2026-03-28T10:05:00Z', 'incremental', 12)
            """.trimIndent()
        )
        seedDb.close()

        val database =
            Room.databaseBuilder(context, FastCheckDatabase::class.java, databaseFile.absolutePath)
                .addMigrations(
                    FastCheckDatabaseMigrations.MIGRATION_5_6,
                    FastCheckDatabaseMigrations.MIGRATION_6_7,
                    FastCheckDatabaseMigrations.MIGRATION_7_8,
                    FastCheckDatabaseMigrations.MIGRATION_8_9,
                    FastCheckDatabaseMigrations.MIGRATION_9_10,
                    FastCheckDatabaseMigrations.MIGRATION_10_11,
                    FastCheckDatabaseMigrations.MIGRATION_11_12
                )
                .allowMainThreadQueries()
                .build()

        val metadata = database.scannerDao().loadSyncMetadata(5)
        assertThat(metadata?.bootstrapCompletedAt).isEqualTo("2026-03-28T10:05:00Z")
        assertThat(metadata?.lastFullReconcileAt).isEqualTo("2026-03-28T10:05:00Z")

        database.close()
    }

    private fun assertNullableReasonCodeColumn(cursor: Cursor, columnName: String) {
        cursor.use {
            while (it.moveToNext()) {
                if (it.getString(it.getColumnIndexOrThrow("name")) == columnName) {
                    assertThat(it.getInt(it.getColumnIndexOrThrow("notnull"))).isEqualTo(0)
                    return
                }
            }
        }

        error("Column $columnName was not found")
    }

    private fun assertIndexColumns(
        sqliteDb: SupportSQLiteDatabase,
        indexName: String,
        expectedColumns: List<String>,
        tableName: String = "queued_scans"
    ) {
        val indexNames = mutableListOf<String>()
        sqliteDb.query("PRAGMA index_list($tableName)").use { cursor ->
            while (cursor.moveToNext()) {
                indexNames += cursor.getString(cursor.getColumnIndexOrThrow("name"))
            }
        }

        assertThat(indexNames).contains(indexName)

        val actualColumns = mutableListOf<String>()
        sqliteDb.query("PRAGMA index_info('$indexName')").use { cursor ->
            while (cursor.moveToNext()) {
                actualColumns += cursor.getString(cursor.getColumnIndexOrThrow("name"))
            }
        }

        assertThat(actualColumns).containsExactlyElementsIn(expectedColumns).inOrder()
    }

    private fun createVersion2Schema(databaseFile: File) {
        val database = SQLiteDatabase.openOrCreateDatabase(databaseFile, null)

        database.execSQL(
            """
            CREATE TABLE IF NOT EXISTS attendees (
                id INTEGER NOT NULL,
                eventId INTEGER NOT NULL,
                ticketCode TEXT NOT NULL,
                firstName TEXT,
                lastName TEXT,
                email TEXT,
                ticketType TEXT,
                allowedCheckins INTEGER NOT NULL,
                checkinsRemaining INTEGER NOT NULL,
                paymentStatus TEXT,
                isCurrentlyInside INTEGER NOT NULL,
                updatedAt TEXT,
                PRIMARY KEY(id)
            )
            """.trimIndent()
        )
        database.execSQL(
            "CREATE UNIQUE INDEX IF NOT EXISTS index_attendees_eventId_ticketCode ON attendees(eventId, ticketCode)"
        )

        database.execSQL(
            """
            CREATE TABLE IF NOT EXISTS queued_scans (
                id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
                eventId INTEGER NOT NULL,
                ticketCode TEXT NOT NULL,
                idempotencyKey TEXT NOT NULL,
                createdAt INTEGER NOT NULL,
                scannedAt TEXT NOT NULL,
                direction TEXT NOT NULL,
                entranceName TEXT NOT NULL,
                operatorName TEXT NOT NULL,
                replayed INTEGER NOT NULL,
                lastAttemptAt TEXT
            )
            """.trimIndent()
        )
        database.execSQL(
            "CREATE UNIQUE INDEX IF NOT EXISTS index_queued_scans_idempotencyKey ON queued_scans(idempotencyKey)"
        )
        database.execSQL(
            """
            CREATE INDEX IF NOT EXISTS index_queued_scans_replayed_createdAt_id
            ON queued_scans(replayed, createdAt, id)
            """.trimIndent()
        )
        database.execSQL(
            """
            CREATE INDEX IF NOT EXISTS index_queued_scans_replayed_createdAt_id
            ON queued_scans(replayed, createdAt, id)
            """.trimIndent()
        )

        database.execSQL(
            """
            CREATE TABLE IF NOT EXISTS scan_replay_cache (
                id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
                idempotencyKey TEXT NOT NULL,
                status TEXT NOT NULL,
                message TEXT NOT NULL,
                storedAt TEXT NOT NULL,
                terminal INTEGER NOT NULL
            )
            """.trimIndent()
        )
        database.execSQL(
            "CREATE UNIQUE INDEX IF NOT EXISTS index_scan_replay_cache_idempotencyKey ON scan_replay_cache(idempotencyKey)"
        )

        database.execSQL(
            """
            CREATE TABLE IF NOT EXISTS sync_metadata (
                eventId INTEGER NOT NULL,
                lastServerTime TEXT,
                lastSuccessfulSyncAt TEXT,
                lastSyncType TEXT,
                attendeeCount INTEGER NOT NULL,
                PRIMARY KEY(eventId)
            )
            """.trimIndent()
        )

        database.execSQL(
            """
            CREATE TABLE IF NOT EXISTS local_replay_suppression (
                id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
                ticketCode TEXT NOT NULL,
                seenAtEpochMillis INTEGER NOT NULL
            )
            """.trimIndent()
        )
        database.execSQL(
            "CREATE UNIQUE INDEX IF NOT EXISTS index_local_replay_suppression_ticketCode ON local_replay_suppression(ticketCode)"
        )

        database.execSQL(
            """
            CREATE TABLE IF NOT EXISTS latest_flush_snapshot (
                snapshotId INTEGER NOT NULL,
                executionStatus TEXT NOT NULL,
                uploadedCount INTEGER NOT NULL,
                retryableRemainingCount INTEGER NOT NULL,
                authExpired INTEGER NOT NULL,
                backlogRemaining INTEGER NOT NULL,
                summaryMessage TEXT NOT NULL,
                completedAt TEXT NOT NULL,
                PRIMARY KEY(snapshotId)
            )
            """.trimIndent()
        )

        database.execSQL(
            """
            CREATE TABLE IF NOT EXISTS recent_flush_outcomes (
                id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
                outcomeOrder INTEGER NOT NULL,
                idempotencyKey TEXT NOT NULL,
                ticketCode TEXT NOT NULL,
                outcome TEXT NOT NULL,
                message TEXT NOT NULL,
                completedAt TEXT NOT NULL
            )
            """.trimIndent()
        )

        database.execSQL(
            """
            INSERT INTO scan_replay_cache (id, idempotencyKey, status, message, storedAt, terminal)
            VALUES (1, 'idem-cache', 'duplicate', 'Already checked in', '2026-03-24T06:00:00Z', 1)
            """.trimIndent()
        )
        database.execSQL(
            """
            INSERT INTO recent_flush_outcomes
                (id, outcomeOrder, idempotencyKey, ticketCode, outcome, message, completedAt)
            VALUES
                (1, 0, 'idem-outcome', 'VG-001', 'DUPLICATE', 'Already checked in', '2026-03-24T06:00:00Z')
            """.trimIndent()
        )

        database.version = 2
        database.close()
    }

    private fun createVersion6Schema(databaseFile: File) {
        createVersion5Schema(databaseFile)
        val database = SQLiteDatabase.openDatabase(databaseFile.absolutePath, null, SQLiteDatabase.OPEN_READWRITE)
        database.execSQL("ALTER TABLE attendees ADD COLUMN checkedInAt TEXT")
        database.execSQL("ALTER TABLE attendees ADD COLUMN checkedOutAt TEXT")
        database.version = 6
        database.close()
    }

    private fun createVersion11SchemaWithDurableEvidence(databaseFile: File) {
        createVersion6Schema(databaseFile)
        val raw = SQLiteDatabase.openDatabase(databaseFile.absolutePath, null, SQLiteDatabase.OPEN_READWRITE)
        val database = Class.forName("androidx.sqlite.db.framework.FrameworkSQLiteDatabase")
            .getDeclaredConstructor(SQLiteDatabase::class.java)
            .apply { isAccessible = true }
            .newInstance(raw) as SupportSQLiteDatabase
        FastCheckDatabaseMigrations.MIGRATION_6_7.migrate(database)
        FastCheckDatabaseMigrations.MIGRATION_7_8.migrate(database)
        FastCheckDatabaseMigrations.MIGRATION_8_9.migrate(database)
        FastCheckDatabaseMigrations.MIGRATION_9_10.migrate(database)
        FastCheckDatabaseMigrations.MIGRATION_10_11.migrate(database)
        listOf(
            "queued_scans", "attendees", "sync_metadata", "local_admission_overlays",
            "quarantined_scans", "local_replay_suppression", "latest_flush_snapshot",
            "recent_flush_outcomes", "event_local_buckets"
        ).forEach { database.execSQL("DELETE FROM $it") }
        database.execSQL(
            """
            INSERT INTO queued_scans
                (id, eventId, ticketCode, idempotencyKey, createdAt, scannedAt, direction,
                 entranceName, operatorName, replayed, lastAttemptAt)
            VALUES (101, 41, 'Q-41', 'queue-41', 1234, '2026-08-03T09:00:00Z', 'in',
                    'North', 'Operator', 0, '2026-08-03T09:01:00Z')
            """.trimIndent()
        )
        database.execSQL(
            """
            INSERT INTO attendees
                (id, eventId, ticketCode, firstName, lastName, email, ticketType, allowedCheckins,
                 checkinsRemaining, paymentStatus, isCurrentlyInside, checkedInAt, checkedOutAt, updatedAt)
            VALUES (201, 41, 'T-41', 'Ada', 'Lovelace', 'ada@example.test', 'VIP', 2, 1,
                    'completed', 1, '2026-08-03T08:00:00Z', NULL, '2026-08-03T08:30:00Z')
            """.trimIndent()
        )
        database.execSQL(
            """
            INSERT INTO local_admission_overlays
                (id, eventId, attendeeId, ticketCode, idempotencyKey, direction, state,
                 createdAtEpochMillis, overlayScannedAt, expectedRemainingAfterOverlay,
                 operatorName, entranceName, conflictReasonCode, conflictMessage)
            VALUES (301, 41, 201, 'T-41', 'overlay-41', 'in', 'CONFLICT_REJECTED', 1300,
                    '2026-08-03T09:00:01Z', 0, 'Operator', 'North', 'capacity', 'Full')
            """.trimIndent()
        )
        database.execSQL(
            """
            INSERT INTO quarantined_scans
                (id, originalQueueId, eventId, ticketCode, idempotencyKey, createdAt, scannedAt,
                 direction, entranceName, operatorName, lastAttemptAt, quarantineReason,
                 quarantineMessage, quarantinedAt, batchAttributed, overlayStateAtQuarantine)
            VALUES (401, 101, 41, 'X-41', 'quarantine-41', 1400, '2026-08-03T09:00:02Z',
                    'in', 'North', 'Operator', '2026-08-03T09:02:00Z', 'contract_error',
                    'Bad response', '2026-08-03T09:03:00Z', 1, 'PENDING_LOCAL')
            """.trimIndent()
        )
        database.execSQL(
            """
            INSERT INTO sync_metadata
                (eventId, lastServerTime, lastSuccessfulSyncAt, lastSyncType, attendeeCount,
                 bootstrapCompletedAt, lastAttemptedSyncAt, consecutiveFailures, lastErrorCode,
                 lastErrorAt, lastFullReconcileAt, incrementalCyclesSinceFullReconcile,
                 consecutiveIntegrityFailures, integrityFailuresInForegroundSession,
                 lastInvalidationsCheckpoint, lastEventSyncVersion)
            VALUES (41, '2026-08-03T08:30:00Z', '2026-08-03T08:30:00Z', 'incremental', 1,
                    '2026-08-03T07:00:00Z', '2026-08-03T08:29:00Z', 2, 'timeout',
                    '2026-08-03T08:29:30Z', '2026-08-03T07:00:00Z', 3, 4, 5, 6, 7)
            """.trimIndent()
        )
        database.execSQL("INSERT INTO local_replay_suppression (id, ticketCode, seenAtEpochMillis) VALUES (501, 'T-41', 1500)")
        database.execSQL(
            """
            INSERT INTO latest_flush_snapshot
                (snapshotId, executionStatus, uploadedCount, retryableRemainingCount, authExpired,
                 backlogRemaining, summaryMessage, completedAt)
            VALUES (1, 'COMPLETED', 1, 0, 0, 0, 'Legacy display', '2026-08-03T09:04:00Z')
            """.trimIndent()
        )
        database.execSQL(
            """
            INSERT INTO recent_flush_outcomes
                (id, outcomeOrder, idempotencyKey, ticketCode, outcome, message, reasonCode, completedAt)
            VALUES (601, 0, 'legacy-outcome', 'T-41', 'SUCCESS', 'Legacy', NULL,
                    '2026-08-03T09:04:00Z')
            """.trimIndent()
        )
        database.version = 11
        database.close()
    }

    private fun createVersion3Schema(databaseFile: File) {
        val database = SQLiteDatabase.openOrCreateDatabase(databaseFile, null)

        database.execSQL(
            """
            CREATE TABLE IF NOT EXISTS attendees (
                id INTEGER NOT NULL,
                eventId INTEGER NOT NULL,
                ticketCode TEXT NOT NULL,
                firstName TEXT,
                lastName TEXT,
                email TEXT,
                ticketType TEXT,
                allowedCheckins INTEGER NOT NULL,
                checkinsRemaining INTEGER NOT NULL,
                paymentStatus TEXT,
                isCurrentlyInside INTEGER NOT NULL,
                updatedAt TEXT,
                PRIMARY KEY(id)
            )
            """.trimIndent()
        )
        database.execSQL(
            "CREATE UNIQUE INDEX IF NOT EXISTS index_attendees_eventId_ticketCode ON attendees(eventId, ticketCode)"
        )

        database.execSQL(
            """
            CREATE TABLE IF NOT EXISTS queued_scans (
                id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
                eventId INTEGER NOT NULL,
                ticketCode TEXT NOT NULL,
                idempotencyKey TEXT NOT NULL,
                createdAt INTEGER NOT NULL,
                scannedAt TEXT NOT NULL,
                direction TEXT NOT NULL,
                entranceName TEXT NOT NULL,
                operatorName TEXT NOT NULL,
                replayed INTEGER NOT NULL,
                lastAttemptAt TEXT
            )
            """.trimIndent()
        )
        database.execSQL(
            "CREATE UNIQUE INDEX IF NOT EXISTS index_queued_scans_idempotencyKey ON queued_scans(idempotencyKey)"
        )

        database.execSQL(
            """
            CREATE TABLE IF NOT EXISTS scan_replay_cache (
                id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
                idempotencyKey TEXT NOT NULL,
                status TEXT NOT NULL,
                message TEXT NOT NULL,
                storedAt TEXT NOT NULL,
                terminal INTEGER NOT NULL,
                reasonCode TEXT
            )
            """.trimIndent()
        )
        database.execSQL(
            "CREATE UNIQUE INDEX IF NOT EXISTS index_scan_replay_cache_idempotencyKey ON scan_replay_cache(idempotencyKey)"
        )

        database.execSQL(
            """
            CREATE TABLE IF NOT EXISTS sync_metadata (
                eventId INTEGER NOT NULL,
                lastServerTime TEXT,
                lastSuccessfulSyncAt TEXT,
                lastSyncType TEXT,
                attendeeCount INTEGER NOT NULL,
                PRIMARY KEY(eventId)
            )
            """.trimIndent()
        )

        database.execSQL(
            """
            CREATE TABLE IF NOT EXISTS local_replay_suppression (
                id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
                ticketCode TEXT NOT NULL,
                seenAtEpochMillis INTEGER NOT NULL
            )
            """.trimIndent()
        )
        database.execSQL(
            "CREATE UNIQUE INDEX IF NOT EXISTS index_local_replay_suppression_ticketCode ON local_replay_suppression(ticketCode)"
        )

        database.execSQL(
            """
            CREATE TABLE IF NOT EXISTS latest_flush_snapshot (
                snapshotId INTEGER NOT NULL,
                executionStatus TEXT NOT NULL,
                uploadedCount INTEGER NOT NULL,
                retryableRemainingCount INTEGER NOT NULL,
                authExpired INTEGER NOT NULL,
                backlogRemaining INTEGER NOT NULL,
                summaryMessage TEXT NOT NULL,
                completedAt TEXT NOT NULL,
                PRIMARY KEY(snapshotId)
            )
            """.trimIndent()
        )

        database.execSQL(
            """
            CREATE TABLE IF NOT EXISTS recent_flush_outcomes (
                id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
                outcomeOrder INTEGER NOT NULL,
                idempotencyKey TEXT NOT NULL,
                ticketCode TEXT NOT NULL,
                outcome TEXT NOT NULL,
                message TEXT NOT NULL,
                completedAt TEXT NOT NULL,
                reasonCode TEXT
            )
            """.trimIndent()
        )

        database.execSQL(
            """
            INSERT INTO queued_scans
                (id, eventId, ticketCode, idempotencyKey, createdAt, scannedAt, direction, entranceName, operatorName, replayed, lastAttemptAt)
            VALUES
                (1, 5, 'VG-REPLAYED', 'idem-replayed', 50, '2026-03-24T05:59:00Z', 'in', 'Main', 'Op 1', 1, '2026-03-24T06:00:00Z'),
                (2, 5, 'VG-100', 'idem-100', 100, '2026-03-24T06:01:00Z', 'in', 'Main', 'Op 1', 0, NULL),
                (3, 5, 'VG-200', 'idem-200', 100, '2026-03-24T06:02:00Z', 'in', 'Main', 'Op 1', 0, NULL)
            """.trimIndent()
        )

        database.version = 3
        database.close()
    }

    private fun createVersion4SchemaWithNormalizationCollisions(databaseFile: File) {
        val database = SQLiteDatabase.openOrCreateDatabase(databaseFile, null)

        database.execSQL(
            """
            CREATE TABLE IF NOT EXISTS attendees (
                id INTEGER NOT NULL,
                eventId INTEGER NOT NULL,
                ticketCode TEXT NOT NULL,
                firstName TEXT,
                lastName TEXT,
                email TEXT,
                ticketType TEXT,
                allowedCheckins INTEGER NOT NULL,
                checkinsRemaining INTEGER NOT NULL,
                paymentStatus TEXT,
                isCurrentlyInside INTEGER NOT NULL,
                updatedAt TEXT,
                PRIMARY KEY(id)
            )
            """.trimIndent()
        )
        database.execSQL(
            "CREATE UNIQUE INDEX IF NOT EXISTS index_attendees_eventId_ticketCode ON attendees(eventId, ticketCode)"
        )
        database.execSQL(
            """
            CREATE TABLE IF NOT EXISTS queued_scans (
                id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
                eventId INTEGER NOT NULL,
                ticketCode TEXT NOT NULL,
                idempotencyKey TEXT NOT NULL,
                createdAt INTEGER NOT NULL,
                scannedAt TEXT NOT NULL,
                direction TEXT NOT NULL,
                entranceName TEXT NOT NULL,
                operatorName TEXT NOT NULL,
                replayed INTEGER NOT NULL,
                lastAttemptAt TEXT
            )
            """.trimIndent()
        )
        database.execSQL(
            "CREATE UNIQUE INDEX IF NOT EXISTS index_queued_scans_idempotencyKey ON queued_scans(idempotencyKey)"
        )
        database.execSQL(
            """
            CREATE INDEX IF NOT EXISTS index_queued_scans_replayed_createdAt_id
            ON queued_scans(replayed, createdAt, id)
            """.trimIndent()
        )
        database.execSQL(
            """
            CREATE TABLE IF NOT EXISTS scan_replay_cache (
                id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
                idempotencyKey TEXT NOT NULL,
                status TEXT NOT NULL,
                message TEXT NOT NULL,
                storedAt TEXT NOT NULL,
                terminal INTEGER NOT NULL,
                reasonCode TEXT
            )
            """.trimIndent()
        )
        database.execSQL(
            "CREATE UNIQUE INDEX IF NOT EXISTS index_scan_replay_cache_idempotencyKey ON scan_replay_cache(idempotencyKey)"
        )
        database.execSQL(
            """
            CREATE TABLE IF NOT EXISTS sync_metadata (
                eventId INTEGER NOT NULL,
                lastServerTime TEXT,
                lastSuccessfulSyncAt TEXT,
                lastSyncType TEXT,
                attendeeCount INTEGER NOT NULL,
                PRIMARY KEY(eventId)
            )
            """.trimIndent()
        )
        database.execSQL(
            """
            CREATE TABLE IF NOT EXISTS local_replay_suppression (
                id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
                ticketCode TEXT NOT NULL,
                seenAtEpochMillis INTEGER NOT NULL
            )
            """.trimIndent()
        )
        database.execSQL(
            "CREATE UNIQUE INDEX IF NOT EXISTS index_local_replay_suppression_ticketCode ON local_replay_suppression(ticketCode)"
        )
        database.execSQL(
            """
            CREATE TABLE IF NOT EXISTS latest_flush_snapshot (
                snapshotId INTEGER NOT NULL,
                executionStatus TEXT NOT NULL,
                uploadedCount INTEGER NOT NULL,
                retryableRemainingCount INTEGER NOT NULL,
                authExpired INTEGER NOT NULL,
                backlogRemaining INTEGER NOT NULL,
                summaryMessage TEXT NOT NULL,
                completedAt TEXT NOT NULL,
                PRIMARY KEY(snapshotId)
            )
            """.trimIndent()
        )
        database.execSQL(
            """
            CREATE TABLE IF NOT EXISTS recent_flush_outcomes (
                id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
                outcomeOrder INTEGER NOT NULL,
                idempotencyKey TEXT NOT NULL,
                ticketCode TEXT NOT NULL,
                outcome TEXT NOT NULL,
                message TEXT NOT NULL,
                completedAt TEXT NOT NULL,
                reasonCode TEXT
            )
            """.trimIndent()
        )
        database.execSQL(
            """
            INSERT INTO attendees
                (id, eventId, ticketCode, firstName, lastName, email, ticketType, allowedCheckins, checkinsRemaining, paymentStatus, isCurrentlyInside, updatedAt)
            VALUES
                (10, 5, ' VG-COLLAPSE ', 'Older', 'User', 'older@example.com', 'General', 1, 1, 'completed', 0, '2026-03-24T12:00:00Z'),
                (11, 5, 'VG-COLLAPSE', 'Newer', 'User', 'newer@example.com', 'General', 1, 1, 'completed', 0, '2026-03-24T12:05:00Z')
            """.trimIndent()
        )
        database.execSQL(
            """
            INSERT INTO local_replay_suppression (id, ticketCode, seenAtEpochMillis)
            VALUES
                (1, ' VG-COLLAPSE ', 1000),
                (2, 'VG-COLLAPSE', 2000)
            """.trimIndent()
        )
        database.execSQL(
            """
            INSERT INTO queued_scans
                (id, eventId, ticketCode, idempotencyKey, createdAt, scannedAt, direction, entranceName, operatorName, replayed, lastAttemptAt)
            VALUES
                (1, 5, '  VG-QUEUE-1' || char(13) || char(10), 'idem-queue-1', 100, '2026-03-24T12:10:00Z', 'in', 'Main', 'Migration', 0, NULL)
            """.trimIndent()
        )
        database.execSQL(
            """
            INSERT INTO recent_flush_outcomes
                (id, outcomeOrder, idempotencyKey, ticketCode, outcome, message, completedAt, reasonCode)
            VALUES
                (1, 0, 'idem-outcome-1', '  VG-OUTCOME-1' || char(9), 'DUPLICATE', 'Already checked in', '2026-03-24T12:11:00Z', NULL)
            """.trimIndent()
        )

        database.version = 4
        database.close()
    }

    private fun createVersion5Schema(databaseFile: File) {
        databaseFile.parentFile?.mkdirs()
        val database = SQLiteDatabase.openOrCreateDatabase(databaseFile, null)

        database.execSQL(
            """
            CREATE TABLE IF NOT EXISTS attendees (
                id INTEGER NOT NULL,
                eventId INTEGER NOT NULL,
                ticketCode TEXT NOT NULL,
                firstName TEXT,
                lastName TEXT,
                email TEXT,
                ticketType TEXT,
                allowedCheckins INTEGER NOT NULL,
                checkinsRemaining INTEGER NOT NULL,
                paymentStatus TEXT,
                isCurrentlyInside INTEGER NOT NULL,
                updatedAt TEXT,
                PRIMARY KEY(id)
            )
            """.trimIndent()
        )
        database.execSQL(
            "CREATE UNIQUE INDEX IF NOT EXISTS index_attendees_eventId_ticketCode ON attendees(eventId, ticketCode)"
        )
        database.execSQL(
            """
            CREATE TABLE IF NOT EXISTS queued_scans (
                id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
                eventId INTEGER NOT NULL,
                ticketCode TEXT NOT NULL,
                idempotencyKey TEXT NOT NULL,
                createdAt INTEGER NOT NULL,
                scannedAt TEXT NOT NULL,
                direction TEXT NOT NULL,
                entranceName TEXT NOT NULL,
                operatorName TEXT NOT NULL,
                replayed INTEGER NOT NULL,
                lastAttemptAt TEXT
            )
            """.trimIndent()
        )
        database.execSQL(
            "CREATE UNIQUE INDEX IF NOT EXISTS index_queued_scans_idempotencyKey ON queued_scans(idempotencyKey)"
        )
        database.execSQL(
            """
            CREATE INDEX IF NOT EXISTS index_queued_scans_replayed_createdAt_id
            ON queued_scans(replayed, createdAt, id)
            """.trimIndent()
        )
        database.execSQL(
            """
            CREATE TABLE IF NOT EXISTS scan_replay_cache (
                id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
                idempotencyKey TEXT NOT NULL,
                status TEXT NOT NULL,
                message TEXT NOT NULL,
                storedAt TEXT NOT NULL,
                terminal INTEGER NOT NULL,
                reasonCode TEXT
            )
            """.trimIndent()
        )
        database.execSQL(
            "CREATE UNIQUE INDEX IF NOT EXISTS index_scan_replay_cache_idempotencyKey ON scan_replay_cache(idempotencyKey)"
        )
        database.execSQL(
            """
            CREATE TABLE IF NOT EXISTS sync_metadata (
                eventId INTEGER NOT NULL,
                lastServerTime TEXT,
                lastSuccessfulSyncAt TEXT,
                lastSyncType TEXT,
                attendeeCount INTEGER NOT NULL,
                PRIMARY KEY(eventId)
            )
            """.trimIndent()
        )
        database.execSQL(
            """
            CREATE TABLE IF NOT EXISTS local_replay_suppression (
                id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
                ticketCode TEXT NOT NULL,
                seenAtEpochMillis INTEGER NOT NULL
            )
            """.trimIndent()
        )
        database.execSQL(
            "CREATE UNIQUE INDEX IF NOT EXISTS index_local_replay_suppression_ticketCode ON local_replay_suppression(ticketCode)"
        )
        database.execSQL(
            """
            CREATE TABLE IF NOT EXISTS latest_flush_snapshot (
                snapshotId INTEGER NOT NULL,
                executionStatus TEXT NOT NULL,
                uploadedCount INTEGER NOT NULL,
                retryableRemainingCount INTEGER NOT NULL,
                authExpired INTEGER NOT NULL,
                backlogRemaining INTEGER NOT NULL,
                summaryMessage TEXT NOT NULL,
                completedAt TEXT NOT NULL,
                PRIMARY KEY(snapshotId)
            )
            """.trimIndent()
        )
        database.execSQL(
            """
            CREATE TABLE IF NOT EXISTS recent_flush_outcomes (
                id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
                outcomeOrder INTEGER NOT NULL,
                idempotencyKey TEXT NOT NULL,
                ticketCode TEXT NOT NULL,
                outcome TEXT NOT NULL,
                message TEXT NOT NULL,
                reasonCode TEXT,
                completedAt TEXT NOT NULL
            )
            """.trimIndent()
        )
        database.execSQL(
            """
            INSERT INTO attendees
                (id, eventId, ticketCode, firstName, lastName, email, ticketType, allowedCheckins, checkinsRemaining, paymentStatus, isCurrentlyInside, updatedAt)
            VALUES
                (501, 5, 'VG-V5-001', 'Alex', 'Existing', 'alex@example.com', 'VIP', 2, 1, 'completed', 1, '2026-03-28T10:00:00Z')
            """.trimIndent()
        )
        database.version = 5
        database.close()
    }

    private fun createVersion3SchemaWithNormalizationCollisions(databaseFile: File) {
        createVersion3Schema(databaseFile)
        val database = SQLiteDatabase.openOrCreateDatabase(databaseFile, null)
        database.execSQL(
            """
            INSERT INTO attendees
                (id, eventId, ticketCode, firstName, lastName, email, ticketType, allowedCheckins, checkinsRemaining, paymentStatus, isCurrentlyInside, updatedAt)
            VALUES
                (30, 5, ' VG-V3-COLLAPSE ', 'Older', 'User', 'older-v3@example.com', 'General', 1, 1, 'completed', 0, '2026-03-24T12:00:00Z'),
                (31, 5, 'VG-V3-COLLAPSE', 'Newer', 'User', 'newer-v3@example.com', 'General', 1, 1, 'completed', 0, '2026-03-24T12:05:00Z')
            """.trimIndent()
        )
        database.execSQL(
            """
            INSERT INTO local_replay_suppression (id, ticketCode, seenAtEpochMillis)
            VALUES
                (3, ' VG-V3-COLLAPSE ', 3000),
                (4, 'VG-V3-COLLAPSE', 3100)
            """.trimIndent()
        )
        database.execSQL(
            """
            INSERT INTO recent_flush_outcomes
                (id, outcomeOrder, idempotencyKey, ticketCode, outcome, message, completedAt, reasonCode)
            VALUES
                (2, 0, 'idem-v3-outcome', '  VG-V3-OUTCOME' || char(9), 'DUPLICATE', 'Already checked in', '2026-03-24T12:11:00Z', NULL)
            """.trimIndent()
        )
        database.execSQL(
            """
            INSERT INTO queued_scans
                (id, eventId, ticketCode, idempotencyKey, createdAt, scannedAt, direction, entranceName, operatorName, replayed, lastAttemptAt)
            VALUES
                (4, 5, '  VG-V3-QUEUE' || char(13) || char(10), 'idem-v3-queue', 150, '2026-03-24T12:20:00Z', 'in', 'Main', 'Migration', 0, NULL)
            """.trimIndent()
        )
        database.close()
    }

    private fun createVersion2SchemaWithNormalizationCollisions(databaseFile: File) {
        val database = SQLiteDatabase.openOrCreateDatabase(databaseFile, null)
        database.execSQL(
            """
            CREATE TABLE IF NOT EXISTS attendees (
                id INTEGER NOT NULL,
                eventId INTEGER NOT NULL,
                ticketCode TEXT NOT NULL,
                firstName TEXT,
                lastName TEXT,
                email TEXT,
                ticketType TEXT,
                allowedCheckins INTEGER NOT NULL,
                checkinsRemaining INTEGER NOT NULL,
                paymentStatus TEXT,
                isCurrentlyInside INTEGER NOT NULL,
                updatedAt TEXT,
                PRIMARY KEY(id)
            )
            """.trimIndent()
        )
        database.execSQL(
            "CREATE UNIQUE INDEX IF NOT EXISTS index_attendees_eventId_ticketCode ON attendees(eventId, ticketCode)"
        )
        database.execSQL(
            """
            CREATE TABLE IF NOT EXISTS queued_scans (
                id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
                eventId INTEGER NOT NULL,
                ticketCode TEXT NOT NULL,
                idempotencyKey TEXT NOT NULL,
                createdAt INTEGER NOT NULL,
                scannedAt TEXT NOT NULL,
                direction TEXT NOT NULL,
                entranceName TEXT NOT NULL,
                operatorName TEXT NOT NULL,
                replayed INTEGER NOT NULL,
                lastAttemptAt TEXT
            )
            """.trimIndent()
        )
        database.execSQL(
            "CREATE UNIQUE INDEX IF NOT EXISTS index_queued_scans_idempotencyKey ON queued_scans(idempotencyKey)"
        )
        database.execSQL(
            """
            CREATE TABLE IF NOT EXISTS scan_replay_cache (
                id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
                idempotencyKey TEXT NOT NULL,
                status TEXT NOT NULL,
                message TEXT NOT NULL,
                storedAt TEXT NOT NULL,
                terminal INTEGER NOT NULL
            )
            """.trimIndent()
        )
        database.execSQL(
            "CREATE UNIQUE INDEX IF NOT EXISTS index_scan_replay_cache_idempotencyKey ON scan_replay_cache(idempotencyKey)"
        )
        database.execSQL(
            """
            CREATE TABLE IF NOT EXISTS sync_metadata (
                eventId INTEGER NOT NULL,
                lastServerTime TEXT,
                lastSuccessfulSyncAt TEXT,
                lastSyncType TEXT,
                attendeeCount INTEGER NOT NULL,
                PRIMARY KEY(eventId)
            )
            """.trimIndent()
        )
        database.execSQL(
            """
            CREATE TABLE IF NOT EXISTS local_replay_suppression (
                id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
                ticketCode TEXT NOT NULL,
                seenAtEpochMillis INTEGER NOT NULL
            )
            """.trimIndent()
        )
        database.execSQL(
            "CREATE UNIQUE INDEX IF NOT EXISTS index_local_replay_suppression_ticketCode ON local_replay_suppression(ticketCode)"
        )
        database.execSQL(
            """
            CREATE TABLE IF NOT EXISTS latest_flush_snapshot (
                snapshotId INTEGER NOT NULL,
                executionStatus TEXT NOT NULL,
                uploadedCount INTEGER NOT NULL,
                retryableRemainingCount INTEGER NOT NULL,
                authExpired INTEGER NOT NULL,
                backlogRemaining INTEGER NOT NULL,
                summaryMessage TEXT NOT NULL,
                completedAt TEXT NOT NULL,
                PRIMARY KEY(snapshotId)
            )
            """.trimIndent()
        )
        database.execSQL(
            """
            CREATE TABLE IF NOT EXISTS recent_flush_outcomes (
                id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
                outcomeOrder INTEGER NOT NULL,
                idempotencyKey TEXT NOT NULL,
                ticketCode TEXT NOT NULL,
                outcome TEXT NOT NULL,
                message TEXT NOT NULL,
                completedAt TEXT NOT NULL
            )
            """.trimIndent()
        )
        database.execSQL(
            """
            INSERT INTO scan_replay_cache (id, idempotencyKey, status, message, storedAt, terminal)
            VALUES (1, 'idem-cache', 'duplicate', 'Already checked in', '2026-03-24T06:00:00Z', 1)
            """.trimIndent()
        )
        database.execSQL(
            """
            INSERT INTO recent_flush_outcomes
                (id, outcomeOrder, idempotencyKey, ticketCode, outcome, message, completedAt)
            VALUES
                (1, 0, 'idem-outcome', 'VG-001', 'DUPLICATE', 'Already checked in', '2026-03-24T06:00:00Z')
            """.trimIndent()
        )
        database.execSQL(
            """
            INSERT INTO attendees
                (id, eventId, ticketCode, firstName, lastName, email, ticketType, allowedCheckins, checkinsRemaining, paymentStatus, isCurrentlyInside, updatedAt)
            VALUES
                (40, 5, ' VG-V2-COLLAPSE ', 'Older', 'User', 'older-v2@example.com', 'General', 1, 1, 'completed', 0, '2026-03-24T12:00:00Z'),
                (41, 5, 'VG-V2-COLLAPSE', 'Newer', 'User', 'newer-v2@example.com', 'General', 1, 1, 'completed', 0, '2026-03-24T12:05:00Z')
            """.trimIndent()
        )
        database.execSQL(
            """
            INSERT INTO local_replay_suppression (id, ticketCode, seenAtEpochMillis)
            VALUES
                (5, ' VG-V2-COLLAPSE ', 4000),
                (6, 'VG-V2-COLLAPSE', 4100)
            """.trimIndent()
        )
        database.execSQL(
            """
            INSERT INTO queued_scans
                (id, eventId, ticketCode, idempotencyKey, createdAt, scannedAt, direction, entranceName, operatorName, replayed, lastAttemptAt)
            VALUES
                (4, 5, '  VG-V2-QUEUE' || char(13) || char(10), 'idem-v2-queue', 175, '2026-03-24T12:30:00Z', 'in', 'Main', 'Migration', 0, NULL)
            """.trimIndent()
        )
        database.execSQL(
            """
            INSERT INTO recent_flush_outcomes
                (id, outcomeOrder, idempotencyKey, ticketCode, outcome, message, completedAt)
            VALUES
                (2, 0, 'idem-v2-outcome', '  VG-V2-OUTCOME' || char(9), 'DUPLICATE', 'Already checked in', '2026-03-24T12:31:00Z')
            """.trimIndent()
        )
        database.version = 2
        database.close()
    }


    private fun assertTableExists(sqliteDb: SupportSQLiteDatabase, tableName: String) {
        sqliteDb.query("SELECT name FROM sqlite_master WHERE type='table' AND name=?", arrayOf(tableName)).use { cursor ->
            assertThat(cursor.moveToFirst()).isTrue()
        }
    }

    private class RecordingPhoenixMobileApi : PhoenixMobileApi {
        var lastUploadBody: UploadScansRequest? = null

        override suspend fun login(body: MobileLoginRequest): MobileLoginResponse {
            error("Not used in this migration test")
        }

        override suspend fun syncAttendees(
            authorization: String,
            since: String?,
            cursor: String?,
            sinceInvalidationId: Long,
            limit: Int
        ): MobileSyncResponse {
            error("Not used in this migration test")
        }

        override suspend fun uploadScans(authorization: String, body: UploadScansRequest): Response<UploadScansResponse> {
            lastUploadBody = body
            return Response.success(
                UploadScansResponse(
                    data =
                        UploadScansPayload(
                            results =
                                body.scans.map { scan ->
                                    UploadedScanResult(
                                        idempotency_key = scan.idempotency_key,
                                        status = "success",
                                        message = "Check-in successful",
                                        reason_code = null
                                    )
                                },
                            processed = body.scans.size
                        ),
                    error = null,
                    message = null
                )
            )
        }
    }

    private fun hasColumn(
        database: SupportSQLiteDatabase,
        tableName: String,
        columnName: String
    ): Boolean =
        database.query("PRAGMA table_info($tableName)").use { cursor ->
            val nameIndex = cursor.getColumnIndex("name")
            while (cursor.moveToNext()) {
                if (cursor.getString(nameIndex) == columnName) {
                    return true
                }
            }
            false
        }

    private fun hasTable(database: SupportSQLiteDatabase, tableName: String): Boolean =
        database.query(
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1",
            arrayOf(tableName)
        ).use { it.moveToFirst() }
}
