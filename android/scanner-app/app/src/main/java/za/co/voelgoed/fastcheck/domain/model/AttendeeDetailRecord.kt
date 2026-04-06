package za.co.voelgoed.fastcheck.domain.model

data class AttendeeDetailRecord(
    val id: Long,
    val eventId: Long,
    val ticketCode: String,
    val firstName: String?,
    val lastName: String?,
    val displayName: String,
    val email: String?,
    val ticketType: String?,
    val paymentStatus: String?,
    val isCurrentlyInside: Boolean,
    val checkedInAt: String?,
    val checkedOutAt: String?,
    val allowedCheckins: Int,
    val checkinsRemaining: Int,
    val updatedAt: String?,
    val localOverlayState: String?,
    val localConflictReasonCode: String?,
    val localConflictMessage: String?,
    val localOverlayScannedAt: String?,
    val expectedRemainingAfterOverlay: Int?
)
