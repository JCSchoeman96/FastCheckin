package za.co.voelgoed.fastcheck.core.designsystem.semantic

fun toAttendanceUiState(
    checkedInAt: String?,
    checkedOutAt: String?,
    isCurrentlyInside: Boolean
): AttendanceUiState {
    val hasCheckedIn = !checkedInAt.isNullOrBlank()
    val hasCheckedOut = !checkedOutAt.isNullOrBlank()

    return when {
        hasCheckedOut && isCurrentlyInside -> AttendanceUiState.Unknown
        hasCheckedOut -> AttendanceUiState.CheckedOut
        isCurrentlyInside && hasCheckedIn -> AttendanceUiState.CurrentlyInside
        isCurrentlyInside -> AttendanceUiState.CurrentlyInside
        hasCheckedIn -> AttendanceUiState.CheckedIn
        else -> AttendanceUiState.NotCheckedIn
    }
}
