package za.co.voelgoed.fastcheck.core.database

import androidx.room.Database
import androidx.room.RoomDatabase
import za.co.voelgoed.fastcheck.data.local.AttendeeEntity
import za.co.voelgoed.fastcheck.data.local.AttendeeLookupDao
import za.co.voelgoed.fastcheck.data.local.LatestFlushSnapshotEntity
import za.co.voelgoed.fastcheck.data.local.LocalReplaySuppressionEntity
import za.co.voelgoed.fastcheck.data.local.QueuedScanEntity
import za.co.voelgoed.fastcheck.data.local.RecentFlushOutcomeEntity
import za.co.voelgoed.fastcheck.data.local.ReplayCacheEntity
import za.co.voelgoed.fastcheck.data.local.ScannerDao
import za.co.voelgoed.fastcheck.data.local.SyncMetadataEntity

@Database(
    entities = [
        AttendeeEntity::class,
        QueuedScanEntity::class,
        ReplayCacheEntity::class,
        SyncMetadataEntity::class,
        LocalReplaySuppressionEntity::class,
        LatestFlushSnapshotEntity::class,
        RecentFlushOutcomeEntity::class
    ],
    version = 6,
    exportSchema = false
)
abstract class FastCheckDatabase : RoomDatabase() {
    abstract fun attendeeLookupDao(): AttendeeLookupDao
    abstract fun scannerDao(): ScannerDao

    companion object {
        const val DATABASE_NAME: String = "fastcheck-scanner.db"
    }
}
