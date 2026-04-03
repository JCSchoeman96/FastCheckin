package za.co.voelgoed.fastcheck.feature.attendees

import za.co.voelgoed.fastcheck.core.designsystem.semantic.StatusTone

data class AttendeeSearchUiState(
    val query: String = "",
    val syncBanner: AttendeeSearchBannerUiModel? = null,
    val selectedAttendee: AttendeeDetailUiModel? = null,
    val results: List<AttendeeSearchResultUiModel> = emptyList(),
    val emptyState: SearchEmptyState = SearchEmptyState.Prompt,
    val actionBanner: AttendeeSearchBannerUiModel? = null,
    val recentUploadBanner: AttendeeSearchBannerUiModel? = null,
    val isSubmittingManualCheckIn: Boolean = false
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

data class AttendeeDetailUiModel(
    val id: Long,
    val displayName: String,
    val ticketCode: String,
    val email: String?,
    val ticketType: String?,
    val paymentLabel: String,
    val paymentTone: StatusTone,
    val attendanceLabel: String,
    val attendanceTone: StatusTone,
    val allowedCheckinsLabel: String,
    val remainingCheckinsLabel: String,
    val checkedInAt: String?,
    val checkedOutAt: String?,
    val updatedAt: String?
)

data class AttendeeSearchBannerUiModel(
    val title: String,
    val message: String,
    val tone: StatusTone
)
