package za.co.voelgoed.fastcheck.domain.model

data class FlushReport(
    val executionStatus: FlushExecutionStatus,
    val itemOutcomes: List<FlushItemResult> = emptyList(),
    val uploadedCount: Int = 0,
    val retryableRemainingCount: Int = 0,
    val authExpired: Boolean = false,
    val backlogRemaining: Boolean = false,
    val summaryMessage: String = "No flush has run yet."
)

data class FlushItemResult(
    val idempotencyKey: String,
    val ticketCode: String,
    val outcome: FlushItemOutcome,
    val message: String
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
