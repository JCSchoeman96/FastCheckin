package za.co.voelgoed.fastcheck.core.database

import androidx.room.migration.Migration
import androidx.sqlite.db.SupportSQLiteDatabase

object FastCheckDatabaseMigrations {
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
}
