package za.co.voelgoed.fastcheck.data.local

import androidx.room.Entity
import androidx.room.ColumnInfo
import androidx.room.Index
import androidx.room.PrimaryKey

@Entity(
    tableName = "event_local_buckets",
    indices = [
        Index(value = ["state"]),
        Index(value = ["lastFlushAttemptAtEpochMillis"])
    ]
)
data class EventLocalBucketEntity(
    @PrimaryKey val eventId: Long,
    val eventName: String? = null,
    val eventShortname: String? = null,
    val state: String,
    val selectedAtEpochMillis: Long,
    val lastActivatedAtEpochMillis: Long,
    val closeRequestedAtEpochMillis: Long?,
    val lastFlushAttemptAtEpochMillis: Long?,
    val lastSuccessfulFlushAtEpochMillis: Long?,
    val lastSuccessfulReconcileAtEpochMillis: Long?,
    val pendingScanCountSnapshot: Int,
    val activeOverlayCountSnapshot: Int,
    @ColumnInfo(defaultValue = "0") val awaitingReconciliationCountSnapshot: Int = 0,
    @ColumnInfo(defaultValue = "0") val conflictCountSnapshot: Int = 0,
    val quarantinedScanCountSnapshot: Int,
    val lastErrorCode: String?,
    val lastErrorMessage: String?,
    val updatedAtEpochMillis: Long
)

object EventLocalBucketState {
    const val ACTIVE: String = "ACTIVE"
    const val PARKED: String = "PARKED"
    const val AUTH_REQUIRED: String = "AUTH_REQUIRED"
    const val CLOSING_REQUESTED: String = "CLOSING_REQUESTED"
    const val SYNCING: String = "SYNCING"
    const val RESOLVED: String = "RESOLVED"
    const val ARCHIVED: String = "ARCHIVED"
    const val QUARANTINED: String = "QUARANTINED"
}
