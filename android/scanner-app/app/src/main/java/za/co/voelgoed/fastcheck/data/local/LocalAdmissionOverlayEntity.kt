package za.co.voelgoed.fastcheck.data.local

import androidx.room.Entity
import androidx.room.Index
import androidx.room.PrimaryKey

@Entity(
    tableName = "local_admission_overlays",
    indices = [
        Index(value = ["idempotencyKey"], unique = true),
        Index(value = ["eventId", "attendeeId"]),
        Index(value = ["eventId", "ticketCode"]),
        Index(value = ["eventId", "state"])
    ]
)
data class LocalAdmissionOverlayEntity(
    @PrimaryKey(autoGenerate = true) val id: Long = 0,
    val eventId: Long,
    val attendeeId: Long,
    val ticketCode: String,
    val idempotencyKey: String,
    val direction: String = "in",
    val state: String,
    val createdAtEpochMillis: Long,
    val overlayScannedAt: String,
    val expectedRemainingAfterOverlay: Int,
    val operatorName: String,
    val entranceName: String,
    val conflictReasonCode: String? = null,
    val conflictMessage: String? = null
)
