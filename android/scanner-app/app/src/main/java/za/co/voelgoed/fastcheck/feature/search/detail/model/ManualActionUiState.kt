package za.co.voelgoed.fastcheck.feature.search.detail.model

import za.co.voelgoed.fastcheck.core.designsystem.semantic.StatusTone

data class ManualActionUiState(
    val isRunning: Boolean = false,
    val feedbackTitle: String? = null,
    val feedbackMessage: String? = null,
    val feedbackTone: StatusTone? = null
)
