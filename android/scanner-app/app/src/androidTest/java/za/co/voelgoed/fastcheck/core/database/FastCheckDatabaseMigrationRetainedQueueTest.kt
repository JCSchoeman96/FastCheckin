package za.co.voelgoed.fastcheck.core.database

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import androidx.room.Room
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.google.common.truth.Truth.assertThat
import java.io.File
import java.time.Clock
import java.time.Instant
import java.time.ZoneOffset
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import za.co.voelgoed.fastcheck.core.network.PhoenixMobileApi
import za.co.voelgoed.fastcheck.core.network.SessionProvider
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
import za.co.voelgoed.fastcheck.domain.model.FlushExecutionStatus

@RunWith(AndroidJUnit4::class)
class FastCheckDatabaseMigrationRetainedQueueTest {
    private lateinit var context: Context
    private lateinit var databaseFile: File
    private var database: FastCheckDatabase? = null

    @Before
    fun setUp() {
        context = InstrumentationRegistry.getInstrumentation().targetContext
        databaseFile = context.getDatabasePath(DATABASE_NAME)
        deleteDatabaseArtifacts()
    }

    @After
    fun tearDown() {
        database?.close()
        deleteDatabaseArtifacts()
    }

    @Test
    fun migratesRetainedQueueAndContinuesFlushRuntime() = runBlocking {
        createVersion2Database(databaseFile)

        val migratedDatabase =
            Room.databaseBuilder(context, FastCheckDatabase::class.java, DATABASE_NAME)
                .addMigrations(
                    FastCheckDatabaseMigrations.MIGRATION_2_3,
                    FastCheckDatabaseMigrations.MIGRATION_3_4
                )
                .allowMainThreadQueries()
                .build()
        database = migratedDatabase

        val scannerDao = migratedDatabase.scannerDao()

        val queuedBeforeFlush = scannerDao.loadQueuedScans()
        assertThat(queuedBeforeFlush).hasSize(1)
        assertThat(queuedBeforeFlush.single().ticketCode).isEqualTo(QUEUED_TICKET_CODE)
        assertThat(scannerDao.countPendingScans()).isEqualTo(1)

        val migratedLegacyOutcomes = scannerDao.loadRecentFlushOutcomes(limit = 10)
        assertThat(migratedLegacyOutcomes).hasSize(1)
        assertThat(migratedLegacyOutcomes.single().ticketCode).isEqualTo(LEGACY_OUTCOME_TICKET_CODE)
        assertThat(migratedLegacyOutcomes.single().reasonCode).isNull()

        val migratedLegacyReplayCache = scannerDao.findReplayCache(LEGACY_REPLAY_CACHE_IDEMPOTENCY_KEY)
        assertThat(migratedLegacyReplayCache).isNotNull()
        assertThat(migratedLegacyReplayCache?.ticketSafeReasonCode()).isNull()
        assertThat(migratedLegacyReplayCache?.message).isEqualTo("Legacy duplicate outcome")

        val repository =
            CurrentPhoenixMobileScanRepository(
                scannerDao = scannerDao,
                remoteDataSource = PhoenixMobileRemoteDataSource(FakePhoenixMobileApi()),
                sessionProvider =
                    object : SessionProvider {
                        override suspend fun bearerToken(): String = "migration-test-token"
                    },
                flushResultClassifier = FlushResultClassifier(),
                clock = Clock.fixed(Instant.parse("2026-03-24T14:30:00Z"), ZoneOffset.UTC)
            )

        val flushReport = repository.flushQueuedScans(maxBatchSize = 10)

        assertThat(flushReport.executionStatus).isEqualTo(FlushExecutionStatus.COMPLETED)
        assertThat(flushReport.uploadedCount).isEqualTo(1)
        assertThat(flushReport.retryableRemainingCount).isEqualTo(0)
        assertThat(flushReport.backlogRemaining).isFalse()
        assertThat(flushReport.itemOutcomes).hasSize(1)
        assertThat(flushReport.itemOutcomes.single().ticketCode).isEqualTo(QUEUED_TICKET_CODE)
        assertThat(flushReport.itemOutcomes.single().reasonCode).isNull()
        assertThat(scannerDao.countPendingScans()).isEqualTo(0)

        val latestSnapshot = scannerDao.loadLatestFlushSnapshot()
        assertThat(latestSnapshot).isNotNull()
        assertThat(latestSnapshot?.executionStatus).isEqualTo(FlushExecutionStatus.COMPLETED.name)

        val persistedOutcome = scannerDao.loadRecentFlushOutcomes(limit = 10).single()
        assertThat(persistedOutcome.ticketCode).isEqualTo(QUEUED_TICKET_CODE)
        assertThat(persistedOutcome.reasonCode).isNull()

        val retainedReplayCache = scannerDao.findReplayCache(LEGACY_REPLAY_CACHE_IDEMPOTENCY_KEY)
        assertThat(retainedReplayCache).isNotNull()
        assertThat(retainedReplayCache?.ticketSafeReasonCode()).isNull()

        val newReplayCache = scannerDao.findReplayCache(QUEUED_IDEMPOTENCY_KEY)
        assertThat(newReplayCache).isNotNull()
        assertThat(newReplayCache?.status).isEqualTo("success")
        assertThat(newReplayCache?.ticketSafeReasonCode()).isNull()
    }

    private fun createVersion2Database(file: File) {
        file.parentFile?.mkdirs()
        val sqliteDatabase = SQLiteDatabase.openOrCreateDatabase(file, null)

        sqliteDatabase.beginTransaction()
        try {
            sqliteDatabase.execSQL(
                """
                CREATE TABLE IF NOT EXISTS `attendees` (
                    `id` INTEGER NOT NULL,
                    `eventId` INTEGER NOT NULL,
                    `ticketCode` TEXT NOT NULL,
                    `firstName` TEXT,
                    `lastName` TEXT,
                    `email` TEXT,
                    `ticketType` TEXT,
                    `allowedCheckins` INTEGER NOT NULL,
                    `checkinsRemaining` INTEGER NOT NULL,
                    `paymentStatus` TEXT,
                    `isCurrentlyInside` INTEGER NOT NULL,
                    `updatedAt` TEXT,
                    PRIMARY KEY(`id`)
                )
                """.trimIndent()
            )
            sqliteDatabase.execSQL(
                "CREATE UNIQUE INDEX IF NOT EXISTS `index_attendees_eventId_ticketCode` ON `attendees` (`eventId`, `ticketCode`)"
            )
            sqliteDatabase.execSQL(
                """
                CREATE TABLE IF NOT EXISTS `queued_scans` (
                    `id` INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
                    `eventId` INTEGER NOT NULL,
                    `ticketCode` TEXT NOT NULL,
                    `idempotencyKey` TEXT NOT NULL,
                    `createdAt` INTEGER NOT NULL,
                    `scannedAt` TEXT NOT NULL,
                    `direction` TEXT NOT NULL,
                    `entranceName` TEXT NOT NULL,
                    `operatorName` TEXT NOT NULL,
                    `replayed` INTEGER NOT NULL,
                    `lastAttemptAt` TEXT
                )
                """.trimIndent()
            )
            sqliteDatabase.execSQL(
                "CREATE UNIQUE INDEX IF NOT EXISTS `index_queued_scans_idempotencyKey` ON `queued_scans` (`idempotencyKey`)"
            )
            sqliteDatabase.execSQL(
                """
                CREATE TABLE IF NOT EXISTS `scan_replay_cache` (
                    `id` INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
                    `idempotencyKey` TEXT NOT NULL,
                    `status` TEXT NOT NULL,
                    `message` TEXT NOT NULL,
                    `storedAt` TEXT NOT NULL,
                    `terminal` INTEGER NOT NULL
                )
                """.trimIndent()
            )
            sqliteDatabase.execSQL(
                "CREATE UNIQUE INDEX IF NOT EXISTS `index_scan_replay_cache_idempotencyKey` ON `scan_replay_cache` (`idempotencyKey`)"
            )
            sqliteDatabase.execSQL(
                """
                CREATE TABLE IF NOT EXISTS `sync_metadata` (
                    `eventId` INTEGER NOT NULL,
                    `lastServerTime` TEXT,
                    `lastSuccessfulSyncAt` TEXT,
                    `lastSyncType` TEXT,
                    `attendeeCount` INTEGER NOT NULL,
                    PRIMARY KEY(`eventId`)
                )
                """.trimIndent()
            )
            sqliteDatabase.execSQL(
                """
                CREATE TABLE IF NOT EXISTS `local_replay_suppression` (
                    `id` INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
                    `ticketCode` TEXT NOT NULL,
                    `seenAtEpochMillis` INTEGER NOT NULL
                )
                """.trimIndent()
            )
            sqliteDatabase.execSQL(
                "CREATE UNIQUE INDEX IF NOT EXISTS `index_local_replay_suppression_ticketCode` ON `local_replay_suppression` (`ticketCode`)"
            )
            sqliteDatabase.execSQL(
                """
                CREATE TABLE IF NOT EXISTS `latest_flush_snapshot` (
                    `snapshotId` INTEGER NOT NULL,
                    `executionStatus` TEXT NOT NULL,
                    `uploadedCount` INTEGER NOT NULL,
                    `retryableRemainingCount` INTEGER NOT NULL,
                    `authExpired` INTEGER NOT NULL,
                    `backlogRemaining` INTEGER NOT NULL,
                    `summaryMessage` TEXT NOT NULL,
                    `completedAt` TEXT NOT NULL,
                    PRIMARY KEY(`snapshotId`)
                )
                """.trimIndent()
            )
            sqliteDatabase.execSQL(
                """
                CREATE TABLE IF NOT EXISTS `recent_flush_outcomes` (
                    `id` INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
                    `outcomeOrder` INTEGER NOT NULL,
                    `idempotencyKey` TEXT NOT NULL,
                    `ticketCode` TEXT NOT NULL,
                    `outcome` TEXT NOT NULL,
                    `message` TEXT NOT NULL,
                    `completedAt` TEXT NOT NULL
                )
                """.trimIndent()
            )

            sqliteDatabase.execSQL(
                """
                INSERT INTO `queued_scans` (
                    `id`,
                    `eventId`,
                    `ticketCode`,
                    `idempotencyKey`,
                    `createdAt`,
                    `scannedAt`,
                    `direction`,
                    `entranceName`,
                    `operatorName`,
                    `replayed`,
                    `lastAttemptAt`
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """.trimIndent(),
                arrayOf<Any?>(
                    1L,
                    EVENT_ID,
                    QUEUED_TICKET_CODE,
                    QUEUED_IDEMPOTENCY_KEY,
                    1_711_290_400_000L,
                    "2026-03-24T12:00:00Z",
                    "in",
                    "Main",
                    "Migration Tester",
                    0,
                    null
                )
            )
            sqliteDatabase.execSQL(
                """
                INSERT INTO `recent_flush_outcomes` (
                    `id`,
                    `outcomeOrder`,
                    `idempotencyKey`,
                    `ticketCode`,
                    `outcome`,
                    `message`,
                    `completedAt`
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
                """.trimIndent(),
                arrayOf<Any?>(
                    1L,
                    0,
                    LEGACY_OUTCOME_IDEMPOTENCY_KEY,
                    LEGACY_OUTCOME_TICKET_CODE,
                    "DUPLICATE",
                    "Legacy duplicate outcome",
                    "2026-03-24T11:59:00Z"
                )
            )
            sqliteDatabase.execSQL(
                """
                INSERT INTO `scan_replay_cache` (
                    `id`,
                    `idempotencyKey`,
                    `status`,
                    `message`,
                    `storedAt`,
                    `terminal`
                ) VALUES (?, ?, ?, ?, ?, ?)
                """.trimIndent(),
                arrayOf<Any?>(
                    1L,
                    LEGACY_REPLAY_CACHE_IDEMPOTENCY_KEY,
                    "duplicate",
                    "Legacy duplicate outcome",
                    "2026-03-24T11:59:00Z",
                    1
                )
            )

            sqliteDatabase.setTransactionSuccessful()
        } finally {
            sqliteDatabase.endTransaction()
            sqliteDatabase.version = 2
            sqliteDatabase.close()
        }
    }

    private fun deleteDatabaseArtifacts() {
        listOf(
            databaseFile,
            File("${databaseFile.path}-wal"),
            File("${databaseFile.path}-shm"),
            File("${databaseFile.path}-journal")
        ).forEach { artifact ->
            if (artifact.exists()) {
                artifact.delete()
            }
        }
    }

    private fun za.co.voelgoed.fastcheck.data.local.ReplayCacheEntity.ticketSafeReasonCode(): String? =
        reasonCode

    private class FakePhoenixMobileApi : PhoenixMobileApi {
        override suspend fun login(body: MobileLoginRequest): MobileLoginResponse {
            error("login is not used by this migration test")
        }

        override suspend fun syncAttendees(
            since: String?,
            cursor: String?,
            limit: Int?
        ): MobileSyncResponse {
            error("syncAttendees is not used by this migration test")
        }

        override suspend fun uploadScans(body: UploadScansRequest): UploadScansResponse {
            val results =
                body.scans.map { scan ->
                    UploadedScanResult(
                        idempotency_key = scan.idempotency_key,
                        status = "success",
                        message = "Check-in successful",
                        reason_code = null
                    )
                }

            return UploadScansResponse(
                data = UploadScansPayload(results = results, processed = body.scans.size),
                error = null,
                message = null
            )
        }
    }

    private companion object {
        const val DATABASE_NAME: String = "migration-retained-queue-test.db"
        const val EVENT_ID: Long = 4L
        const val QUEUED_TICKET_CODE: String = "SMOKE-000001"
        const val QUEUED_IDEMPOTENCY_KEY: String = "queue-idempotency-key"
        const val LEGACY_OUTCOME_IDEMPOTENCY_KEY: String = "legacy-outcome-idempotency-key"
        const val LEGACY_OUTCOME_TICKET_CODE: String = "SMOKE-LEGACY-0001"
        const val LEGACY_REPLAY_CACHE_IDEMPOTENCY_KEY: String = "legacy-replay-cache-idempotency-key"
    }
}
