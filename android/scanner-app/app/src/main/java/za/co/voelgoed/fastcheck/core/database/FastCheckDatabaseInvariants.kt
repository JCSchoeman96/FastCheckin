package za.co.voelgoed.fastcheck.core.database

import androidx.room.RoomDatabase
import androidx.sqlite.db.SupportSQLiteDatabase

object FastCheckDatabaseInvariants {
    fun create(db: SupportSQLiteDatabase) {
        db.execSQL(
            "CREATE UNIQUE INDEX IF NOT EXISTS index_event_local_buckets_single_active " +
                "ON event_local_buckets(state) WHERE state = 'ACTIVE'"
        )
    }
}

object FastCheckDatabaseInvariantCallback : RoomDatabase.Callback() {
    override fun onCreate(db: SupportSQLiteDatabase) {
        FastCheckDatabaseInvariants.create(db)
    }

    override fun onOpen(db: SupportSQLiteDatabase) {
        FastCheckDatabaseInvariants.create(db)
    }
}
