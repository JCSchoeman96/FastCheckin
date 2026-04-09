package za.co.voelgoed.fastcheck.domain.model

data class FlushReport(
    val executionStatus: FlushExecutionStatus,
    val itemOutcomes: List<FlushItemResult> = emptyList(),
    val uploadedCount: Int = 0,
    val retryableRemainingCount: Int = 0,
    val httpStatusCode: Int? = null,
    val retryAfterMillis: Long? = null,
    val rateLimitLimit: Int? = null,
    val rateLimitRemaining: Int? = null,
    val rateLimitResetEpochSeconds: Long? = null,
    val backpressureObserved: Boolean = false,
    val authExpired: Boolean = false,
    val backlogRemaining: Boolean = false,
    val summaryMessage: String = "No flush has run yet."
)

data class FlushItemResult(
    val idempotencyKey: String,
    val ticketCode: String,
    val outcome: FlushItemOutcome,
    val message: String,
    val reasonCode: String? = null
)

enum class FlushExecutionStatus {
    COMPLETED,
    RETRYABLE_FAILURE,
    AUTH_EXPIRED,
    WORKER_FAILURE
}

enum class FlushItemOutcome {
    SUCCESS,
    DUPLICATE,
    TERMINAL_ERROR,
    RETRYABLE_FAILURE,
    AUTH_EXPIRED
}
