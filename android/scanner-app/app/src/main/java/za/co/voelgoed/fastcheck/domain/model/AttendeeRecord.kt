package za.co.voelgoed.fastcheck.domain.model

data class AttendeeRecord(
    val id: Long,
    val eventId: Long,
    val ticketCode: String,
    val fullName: String,
    val ticketType: String?,
    val paymentStatus: String?,
    val isCurrentlyInside: Boolean,
    val updatedAt: String?
)
