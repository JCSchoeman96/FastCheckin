package za.co.voelgoed.fastcheck.domain.model

data class AttendeeSearchRecord(
    val id: Long,
    val eventId: Long,
    val ticketCode: String,
    val displayName: String,
    val email: String?,
    val ticketType: String?,
    val paymentStatus: String?,
    val isCurrentlyInside: Boolean,
    val allowedCheckins: Int,
    val checkinsRemaining: Int
)
