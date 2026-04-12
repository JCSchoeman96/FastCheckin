package za.co.voelgoed.fastcheck.data.local

import androidx.room.Entity
import androidx.room.PrimaryKey

@Entity(tableName = "sync_metadata")
data class SyncMetadataEntity(
    @PrimaryKey val eventId: Long,
    val lastServerTime: String?,
    val lastSuccessfulSyncAt: String?,
    val lastSyncType: String?,
    val attendeeCount: Int,
    val bootstrapCompletedAt: String? = null,
    val lastAttemptedSyncAt: String? = null,
    val consecutiveFailures: Int = 0,
    val lastErrorCode: String? = null,
    val lastErrorAt: String? = null,
    val lastFullReconcileAt: String? = null,
    val incrementalCyclesSinceFullReconcile: Int = 0,
    val consecutiveIntegrityFailures: Int = 0,
    val integrityFailuresInForegroundSession: Int = 0
)
