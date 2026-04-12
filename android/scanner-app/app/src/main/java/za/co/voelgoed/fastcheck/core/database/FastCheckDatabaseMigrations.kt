package za.co.voelgoed.fastcheck.core.database

import androidx.room.migration.Migration
import androidx.sqlite.db.SupportSQLiteDatabase

object FastCheckDatabaseMigrations {
    private const val TRIMMED_TICKET_CODE_SQL: String =
        "trim(ticketCode, ' ' || char(9) || char(10) || char(13))"

    val MIGRATION_2_3: Migration =
        object : Migration(2, 3) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL(
                    "ALTER TABLE recent_flush_outcomes ADD COLUMN reasonCode TEXT"
                )
                db.execSQL(
                    "ALTER TABLE scan_replay_cache ADD COLUMN reasonCode TEXT"
                )
            }
        }

    val MIGRATION_3_4: Migration =
        object : Migration(3, 4) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL(
                    """
                    CREATE INDEX IF NOT EXISTS index_queued_scans_replayed_createdAt_id
                    ON queued_scans(replayed, createdAt, id)
                    """.trimIndent()
                )
            }
        }

    val MIGRATION_4_5: Migration =
        object : Migration(4, 5) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL(
                    """
                    UPDATE queued_scans
                    SET ticketCode = $TRIMMED_TICKET_CODE_SQL
                    WHERE $TRIMMED_TICKET_CODE_SQL != '' AND ticketCode != $TRIMMED_TICKET_CODE_SQL
                    """.trimIndent()
                )
                db.execSQL(
                    """
                    UPDATE recent_flush_outcomes
                    SET ticketCode = $TRIMMED_TICKET_CODE_SQL
                    WHERE $TRIMMED_TICKET_CODE_SQL != '' AND ticketCode != $TRIMMED_TICKET_CODE_SQL
                    """.trimIndent()
                )

                rebuildAttendeesTable(db)
                rebuildReplaySuppressionTable(db)
            }
        }

    val MIGRATION_5_6: Migration =
        object : Migration(5, 6) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("ALTER TABLE attendees ADD COLUMN checkedInAt TEXT")
                db.execSQL("ALTER TABLE attendees ADD COLUMN checkedOutAt TEXT")
            }
        }

    val MIGRATION_6_7: Migration =
        object : Migration(6, 7) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL(
                    """
                    CREATE TABLE IF NOT EXISTS local_admission_overlays (
                        id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
                        eventId INTEGER NOT NULL,
                        attendeeId INTEGER NOT NULL,
                        ticketCode TEXT NOT NULL,
                        idempotencyKey TEXT NOT NULL,
                        direction TEXT NOT NULL,
                        state TEXT NOT NULL,
                        createdAtEpochMillis INTEGER NOT NULL,
                        overlayScannedAt TEXT NOT NULL,
                        expectedRemainingAfterOverlay INTEGER NOT NULL,
                        operatorName TEXT NOT NULL,
                        entranceName TEXT NOT NULL,
                        conflictReasonCode TEXT,
                        conflictMessage TEXT
                    )
                    """.trimIndent()
                )
                db.execSQL(
                    "CREATE UNIQUE INDEX IF NOT EXISTS index_local_admission_overlays_idempotencyKey ON local_admission_overlays(idempotencyKey)"
                )
                db.execSQL(
                    "CREATE INDEX IF NOT EXISTS index_local_admission_overlays_eventId_attendeeId ON local_admission_overlays(eventId, attendeeId)"
                )
                db.execSQL(
                    "CREATE INDEX IF NOT EXISTS index_local_admission_overlays_eventId_ticketCode ON local_admission_overlays(eventId, ticketCode)"
                )
                db.execSQL(
                    "CREATE INDEX IF NOT EXISTS index_local_admission_overlays_eventId_state ON local_admission_overlays(eventId, state)"
                )
            }
        }

    val MIGRATION_8_9: Migration =
        object : Migration(8, 9) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("ALTER TABLE sync_metadata ADD COLUMN bootstrapCompletedAt TEXT")
                db.execSQL("ALTER TABLE sync_metadata ADD COLUMN lastAttemptedSyncAt TEXT")
                db.execSQL(
                    "ALTER TABLE sync_metadata ADD COLUMN consecutiveFailures INTEGER NOT NULL DEFAULT 0"
                )
                db.execSQL("ALTER TABLE sync_metadata ADD COLUMN lastErrorCode TEXT")
                db.execSQL("ALTER TABLE sync_metadata ADD COLUMN lastErrorAt TEXT")
                db.execSQL("ALTER TABLE sync_metadata ADD COLUMN lastFullReconcileAt TEXT")
                db.execSQL(
                    """
                    ALTER TABLE sync_metadata ADD COLUMN incrementalCyclesSinceFullReconcile INTEGER NOT NULL DEFAULT 0
                    """.trimIndent()
                )
                db.execSQL(
                    """
                    ALTER TABLE sync_metadata ADD COLUMN consecutiveIntegrityFailures INTEGER NOT NULL DEFAULT 0
                    """.trimIndent()
                )
                db.execSQL(
                    """
                    ALTER TABLE sync_metadata ADD COLUMN integrityFailuresInForegroundSession INTEGER NOT NULL DEFAULT 0
                    """.trimIndent()
                )
                db.execSQL(
                    """
                    UPDATE sync_metadata
                    SET bootstrapCompletedAt = lastSuccessfulSyncAt
                    WHERE bootstrapCompletedAt IS NULL AND lastSuccessfulSyncAt IS NOT NULL
                    """.trimIndent()
                )
                db.execSQL(
                    """
                    UPDATE sync_metadata
                    SET lastFullReconcileAt = lastSuccessfulSyncAt
                    WHERE lastFullReconcileAt IS NULL AND lastSuccessfulSyncAt IS NOT NULL
                    """.trimIndent()
                )
            }
        }

    val MIGRATION_7_8: Migration =
        object : Migration(7, 8) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL(
                    """
                    CREATE TABLE IF NOT EXISTS quarantined_scans (
                        id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
                        originalQueueId INTEGER,
                        eventId INTEGER NOT NULL,
                        ticketCode TEXT NOT NULL,
                        idempotencyKey TEXT NOT NULL,
                        createdAt INTEGER NOT NULL,
                        scannedAt TEXT NOT NULL,
                        direction TEXT NOT NULL,
                        entranceName TEXT NOT NULL,
                        operatorName TEXT NOT NULL,
                        lastAttemptAt TEXT,
                        quarantineReason TEXT NOT NULL,
                        quarantineMessage TEXT NOT NULL,
                        quarantinedAt TEXT NOT NULL,
                        batchAttributed INTEGER NOT NULL,
                        overlayStateAtQuarantine TEXT
                    )
                    """.trimIndent()
                )
                db.execSQL(
                    "CREATE UNIQUE INDEX IF NOT EXISTS index_quarantined_scans_idempotencyKey ON quarantined_scans(idempotencyKey)"
                )
                db.execSQL(
                    "CREATE INDEX IF NOT EXISTS index_quarantined_scans_eventId_quarantinedAt ON quarantined_scans(eventId, quarantinedAt)"
                )
                db.execSQL(
                    "CREATE INDEX IF NOT EXISTS index_quarantined_scans_quarantinedAt ON quarantined_scans(quarantinedAt)"
                )
            }
        }

    private fun rebuildAttendeesTable(db: SupportSQLiteDatabase) {
        db.execSQL("ALTER TABLE attendees RENAME TO attendees_legacy")
        db.execSQL(
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
        db.execSQL(
            """
            INSERT INTO attendees (
                id,
                eventId,
                ticketCode,
                firstName,
                lastName,
                email,
                ticketType,
                allowedCheckins,
                checkinsRemaining,
                paymentStatus,
                isCurrentlyInside,
                updatedAt
            )
            SELECT
                attendee.id,
                attendee.eventId,
                CASE
                    WHEN trim(attendee.ticketCode, ' ' || char(9) || char(10) || char(13)) = '' THEN attendee.ticketCode
                    ELSE trim(attendee.ticketCode, ' ' || char(9) || char(10) || char(13))
                END,
                attendee.firstName,
                attendee.lastName,
                attendee.email,
                attendee.ticketType,
                attendee.allowedCheckins,
                attendee.checkinsRemaining,
                attendee.paymentStatus,
                attendee.isCurrentlyInside,
                attendee.updatedAt
            FROM attendees_legacy attendee
            WHERE trim(attendee.ticketCode, ' ' || char(9) || char(10) || char(13)) = ''
                OR NOT EXISTS (
                    SELECT 1
                    FROM attendees_legacy contender
                    WHERE contender.eventId = attendee.eventId
                        AND trim(contender.ticketCode, ' ' || char(9) || char(10) || char(13)) =
                            trim(attendee.ticketCode, ' ' || char(9) || char(10) || char(13))
                        AND trim(contender.ticketCode, ' ' || char(9) || char(10) || char(13)) != ''
                        AND (
                            COALESCE(contender.updatedAt, '') > COALESCE(attendee.updatedAt, '')
                            OR (
                                COALESCE(contender.updatedAt, '') = COALESCE(attendee.updatedAt, '')
                                AND contender.id > attendee.id
                            )
                        )
                )
            """.trimIndent()
        )
        db.execSQL("DROP TABLE attendees_legacy")
        db.execSQL(
            "CREATE UNIQUE INDEX IF NOT EXISTS index_attendees_eventId_ticketCode ON attendees(eventId, ticketCode)"
        )
    }

    private fun rebuildReplaySuppressionTable(db: SupportSQLiteDatabase) {
        db.execSQL("ALTER TABLE local_replay_suppression RENAME TO local_replay_suppression_legacy")
        db.execSQL(
            """
            CREATE TABLE IF NOT EXISTS local_replay_suppression (
                id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
                ticketCode TEXT NOT NULL,
                seenAtEpochMillis INTEGER NOT NULL
            )
            """.trimIndent()
        )
        db.execSQL(
            """
            INSERT INTO local_replay_suppression (
                id,
                ticketCode,
                seenAtEpochMillis
            )
            SELECT
                suppression.id,
                CASE
                    WHEN trim(suppression.ticketCode, ' ' || char(9) || char(10) || char(13)) = '' THEN suppression.ticketCode
                    ELSE trim(suppression.ticketCode, ' ' || char(9) || char(10) || char(13))
                END,
                suppression.seenAtEpochMillis
            FROM local_replay_suppression_legacy suppression
            WHERE trim(suppression.ticketCode, ' ' || char(9) || char(10) || char(13)) = ''
                OR NOT EXISTS (
                    SELECT 1
                    FROM local_replay_suppression_legacy contender
                    WHERE trim(contender.ticketCode, ' ' || char(9) || char(10) || char(13)) =
                        trim(suppression.ticketCode, ' ' || char(9) || char(10) || char(13))
                        AND trim(contender.ticketCode, ' ' || char(9) || char(10) || char(13)) != ''
                        AND (
                            contender.seenAtEpochMillis > suppression.seenAtEpochMillis
                            OR (
                                contender.seenAtEpochMillis = suppression.seenAtEpochMillis
                                AND contender.id > suppression.id
                            )
                        )
                )
            """.trimIndent()
        )
        db.execSQL("DROP TABLE local_replay_suppression_legacy")
        db.execSQL(
            "CREATE UNIQUE INDEX IF NOT EXISTS index_local_replay_suppression_ticketCode ON local_replay_suppression(ticketCode)"
        )
    }
}
