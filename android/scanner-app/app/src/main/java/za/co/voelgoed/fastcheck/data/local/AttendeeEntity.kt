package za.co.voelgoed.fastcheck.data.local

import androidx.room.Entity
import androidx.room.Index
import androidx.room.PrimaryKey

@Entity(
    tableName = "attendees",
    indices = [Index(value = ["eventId", "ticketCode"], unique = true)]
)
data class AttendeeEntity(
    @PrimaryKey val id: Long,
    val eventId: Long,
    val ticketCode: String,
    val firstName: String?,
    val lastName: String?,
    val email: String?,
    val ticketType: String?,
    val allowedCheckins: Int,
    val checkinsRemaining: Int,
    val paymentStatus: String?,
    val isCurrentlyInside: Boolean,
    val checkedInAt: String?,
    val checkedOutAt: String?,
    val updatedAt: String?
)
