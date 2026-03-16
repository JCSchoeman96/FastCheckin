package za.co.voelgoed.fastcheck.feature.queue

data class QueueUiState(
    val ticketCodeInput: String = "",
    val lastActionMessage: String = "Manual debug queue ready.",
    val validationMessage: String? = null,
    val isQueueing: Boolean = false,
    val isFlushing: Boolean = false,
    val directionLabel: String = "IN"
)
