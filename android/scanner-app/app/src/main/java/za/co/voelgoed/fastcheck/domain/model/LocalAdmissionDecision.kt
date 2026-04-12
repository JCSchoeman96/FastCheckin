package za.co.voelgoed.fastcheck.domain.model

sealed interface LocalAdmissionDecision {
    data class Accepted(
        val attendeeId: Long,
        val displayName: String,
        val ticketCode: String,
        val idempotencyKey: String,
        val scannedAt: String,
        val localQueueId: Long
    ) : LocalAdmissionDecision

    data class Rejected(
        val reason: LocalAdmissionRejectReason,
        val displayMessage: String,
        val ticketCode: String,
        val displayName: String? = null
    ) : LocalAdmissionDecision

    data class ReviewRequired(
        val reason: LocalAdmissionReviewReason,
        val displayMessage: String,
        val ticketCode: String,
        val displayName: String? = null
    ) : LocalAdmissionDecision

    data class OperationalFailure(
        val displayMessage: String
    ) : LocalAdmissionDecision
}

enum class LocalAdmissionRejectReason {
    InvalidTicketCode,
    TicketNotFound,
    AlreadyInside,
    NoCheckinsRemaining,
    PaymentBlocked,
    ReplaySuppressed,
    ConflictRequiresResolution
}

enum class LocalAdmissionReviewReason {
    CacheNotTrusted,
    TicketNotInLocalAttendeeList,
    PaymentUnknown,
    MissingSessionContext,
    LocalWriteFailed
}
