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
    val latestFlushSummary: String = "No flush has run yet.",
    val serverResultHint: String = "No server outcomes yet.",
    val directionLabel: String = "IN",
    /** Rows in upload quarantine — not part of [localQueueDepth] / retry backlog. */
    val quarantineCount: Int = 0,
    /** Present when [quarantineCount] &gt; 0: wire reason for the most recent quarantine event. */
    val quarantineLatestReasonLabel: String? = null
)
