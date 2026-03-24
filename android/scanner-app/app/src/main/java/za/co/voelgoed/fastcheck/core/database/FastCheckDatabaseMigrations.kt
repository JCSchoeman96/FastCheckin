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
}
