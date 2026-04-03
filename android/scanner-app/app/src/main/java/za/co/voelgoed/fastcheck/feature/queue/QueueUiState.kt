package za.co.voelgoed.fastcheck.feature.queue

import za.co.voelgoed.fastcheck.core.designsystem.semantic.SyncUiState

data class QueueUiState(
    val ticketCodeInput: String = "",
    val lastActionMessage: String = "Manual debug queue ready.",
    val validationMessage: String? = null,
    val isQueueing: Boolean = false,
    val isFlushing: Boolean = false,
    val localQueueDepth: Int = 0,
    val uploadSemanticState: SyncUiState = SyncUiState.Idle,
    val uploadStateLabel: String = "Idle",
    val serverResultHint: String = "No server outcomes yet.",
    val directionLabel: String = "IN"
)
