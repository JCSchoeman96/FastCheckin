package za.co.voelgoed.fastcheck.data.local

data class MergedAttendeeLookupProjection(
    val id: Long,
    val eventId: Long,
    val ticketCode: String,
    val firstName: String?,
    val lastName: String?,
    val email: String?,
    val ticketType: String?,
    val allowedCheckins: Int,
    val paymentStatus: String?,
    val updatedAt: String?,
    val mergedCheckinsRemaining: Int,
    val mergedIsCurrentlyInside: Boolean,
    val mergedCheckedInAt: String?,
    val mergedCheckedOutAt: String?,
    val activeOverlayState: String?,
    val activeOverlayConflictReasonCode: String?,
    val activeOverlayConflictMessage: String?,
    val activeOverlayScannedAt: String?,
    val expectedRemainingAfterOverlay: Int?
)
