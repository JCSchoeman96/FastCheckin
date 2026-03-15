package za.co.voelgoed.fastcheck.data.local

import androidx.room.Entity
import androidx.room.PrimaryKey

@Entity(tableName = "sync_metadata")
data class SyncMetadataEntity(
    @PrimaryKey val eventId: Long,
    val lastServerTime: String?,
    val lastSuccessfulSyncAt: String?,
    val lastSyncType: String?,
    val attendeeCount: Int
)
