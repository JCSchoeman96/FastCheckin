package za.co.voelgoed.fastcheck.core.database

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import com.google.common.truth.Truth.assertThat
import java.io.File
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

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
    fun migratesVersion2FlushTablesWithoutDroppingExistingData() = runTest {
        createVersion2Schema(databaseFile)

        val database =
            Room.databaseBuilder(context, FastCheckDatabase::class.java, databaseFile.absolutePath)
                .addMigrations(FastCheckDatabaseMigrations.MIGRATION_2_3)
                .allowMainThreadQueries()
                .build()

        val replayCache = database.scannerDao().findReplayCache("idem-cache")
        val outcomes = database.scannerDao().loadRecentFlushOutcomes(limit = 5)

        assertThat(replayCache).isNotNull()
        assertThat(replayCache?.message).isEqualTo("Already checked in")
        assertThat(replayCache?.reasonCode).isNull()
        assertThat(outcomes).hasSize(1)
        assertThat(outcomes.single().ticketCode).isEqualTo("VG-001")
        assertThat(outcomes.single().reasonCode).isNull()

        database.close()
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
}
