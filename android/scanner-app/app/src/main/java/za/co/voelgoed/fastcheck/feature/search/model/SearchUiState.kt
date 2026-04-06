package za.co.voelgoed.fastcheck.feature.search.model

import za.co.voelgoed.fastcheck.core.designsystem.semantic.StatusTone
import za.co.voelgoed.fastcheck.feature.search.detail.model.AttendeeDetailUiState

data class SearchUiState(
    val query: String,
    val canClear: Boolean,
    val localTruthMessage: String,
    val localTruthTone: StatusTone,
    val isShowingDetail: Boolean,
    val results: List<SearchResultRowUiModel>,
    val emptyStateMessage: String,
    val detailUiState: AttendeeDetailUiState? = null
)

data class SearchResultRowUiModel(
    val attendeeId: Long,
    val displayName: String,
    val supportingText: String,
    val statusText: String,
    val statusTone: StatusTone
)
