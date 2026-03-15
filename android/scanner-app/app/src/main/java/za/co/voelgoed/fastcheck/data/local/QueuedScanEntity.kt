package za.co.voelgoed.fastcheck.data.local

import androidx.room.Entity
import androidx.room.Index
import androidx.room.PrimaryKey

@Entity(
    tableName = "queued_scans",
    indices = [Index(value = ["idempotencyKey"], unique = true)]
)
data class QueuedScanEntity(
    @PrimaryKey(autoGenerate = true) val id: Long = 0,
    val eventId: Long,
    val ticketCode: String,
    val idempotencyKey: String,
    val createdAt: Long,
    val scannedAt: String,
    val direction: String = "in",
    val entranceName: String,
    val operatorName: String,
    val replayed: Boolean = false,
    val lastAttemptAt: String? = null
)
