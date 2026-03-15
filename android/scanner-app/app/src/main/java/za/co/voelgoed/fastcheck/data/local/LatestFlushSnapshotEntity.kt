package za.co.voelgoed.fastcheck.data.local

import androidx.room.Entity
import androidx.room.PrimaryKey

@Entity(tableName = "latest_flush_snapshot")
data class LatestFlushSnapshotEntity(
    @PrimaryKey val snapshotId: Int = 1,
    val executionStatus: String,
    val uploadedCount: Int,
    val retryableRemainingCount: Int,
    val authExpired: Boolean,
    val backlogRemaining: Boolean,
    val summaryMessage: String,
    val completedAt: String
)
