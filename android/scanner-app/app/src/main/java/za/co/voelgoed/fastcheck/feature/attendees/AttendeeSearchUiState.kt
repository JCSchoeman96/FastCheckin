package za.co.voelgoed.fastcheck.feature.attendees

import za.co.voelgoed.fastcheck.core.designsystem.semantic.StatusTone

data class AttendeeSearchUiState(
    val query: String = "",
    val syncBanner: AttendeeSearchBannerUiModel? = null,
    val selectedResult: AttendeeSearchResultUiModel? = null,
    val results: List<AttendeeSearchResultUiModel> = emptyList(),
    val emptyState: SearchEmptyState = SearchEmptyState.Prompt
)

enum class SearchEmptyState {
    Prompt,
    NoResults,
    Hidden
}

data class AttendeeSearchResultUiModel(
    val id: Long,
    val displayName: String,
    val ticketCode: String,
    val supportingText: String,
    val statusLabel: String,
    val statusTone: StatusTone
)

data class AttendeeSearchBannerUiModel(
    val title: String,
    val message: String,
    val tone: StatusTone
)
