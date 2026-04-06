package za.co.voelgoed.fastcheck.feature.search.detail.model

import za.co.voelgoed.fastcheck.core.designsystem.semantic.StatusTone

data class AttendeeDetailUiState(
    val displayName: String,
    val ticketCode: String,
    val email: String?,
    val ticketType: String?,
    val paymentStatus: String?,
    val attendanceStatusLabel: String,
    val attendanceStatusTone: StatusTone,
    val allowedCheckinsLabel: String,
    val remainingCheckinsLabel: String,
    val checkedInAt: String?,
    val checkedOutAt: String?,
    val localTruthNote: String,
    val conflictTitle: String? = null,
    val conflictMessage: String? = null,
    val manualActionUiState: ManualActionUiState = ManualActionUiState()
)
