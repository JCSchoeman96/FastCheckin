package za.co.voelgoed.fastcheck.domain.model

/**
 * Operator/support-facing snapshot of local quarantine state: separate from live
 * queue depth and flush reports.
 */
data class QuarantineSummary(
    val totalCount: Int,
    val latestReason: QuarantineReason?,
    val latestMessage: String?,
    val latestQuarantinedAt: String?
)
