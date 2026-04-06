package za.co.voelgoed.fastcheck.data.local

import androidx.room.Entity
import androidx.room.Index
import androidx.room.PrimaryKey

/**
 * Dead-letter store for queued scans that cannot be retried honestly against the
 * current mobile upload contract. Kept separate from [QueuedScanEntity] so live
 * backlog depth stays truthful.
 */
@Entity(
    tableName = "quarantined_scans",
    indices = [
        Index(value = ["idempotencyKey"], unique = true),
        Index(value = ["eventId", "quarantinedAt"]),
        Index(value = ["quarantinedAt"])
    ]
)
data class QuarantinedScanEntity(
    @PrimaryKey(autoGenerate = true) val id: Long = 0,
    val originalQueueId: Long?,
    val eventId: Long,
    val ticketCode: String,
    val idempotencyKey: String,
    val createdAt: Long,
    val scannedAt: String,
    val direction: String,
    val entranceName: String,
    val operatorName: String,
    val lastAttemptAt: String?,
    val quarantineReason: String,
    val quarantineMessage: String,
    val quarantinedAt: String,
    val batchAttributed: Boolean,
    val overlayStateAtQuarantine: String?
)
