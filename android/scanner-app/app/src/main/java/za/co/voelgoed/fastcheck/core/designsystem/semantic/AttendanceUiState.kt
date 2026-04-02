/**
 * Semantic UI state for attendance/check-in presentation.
 *
 * Attendance truth is projected from the current attendee snapshot. The model
 * remains explicit about currently inside vs checked in vs checked out.
 */
package za.co.voelgoed.fastcheck.core.designsystem.semantic

sealed interface AttendanceUiState {
    val tone: StatusTone
    val iconKey: String
    val labelHook: String
    val defaultLabel: String

    data object NotCheckedIn : AttendanceUiState {
        override val tone: StatusTone = StatusTone.Neutral
        override val iconKey: String = "attendance_not_checked_in"
        override val labelHook: String = "attendance.not_checked_in"
        override val defaultLabel: String = "Not checked in"
    }

    data object CheckedIn : AttendanceUiState {
        override val tone: StatusTone = StatusTone.Info
        override val iconKey: String = "attendance_checked_in"
        override val labelHook: String = "attendance.checked_in"
        override val defaultLabel: String = "Checked in"
    }

    data object CurrentlyInside : AttendanceUiState {
        override val tone: StatusTone = StatusTone.Success
        override val iconKey: String = "attendance_currently_inside"
        override val labelHook: String = "attendance.currently_inside"
        override val defaultLabel: String = "Currently inside"
    }

    data object CheckedOut : AttendanceUiState {
        override val tone: StatusTone = StatusTone.Muted
        override val iconKey: String = "attendance_checked_out"
        override val labelHook: String = "attendance.checked_out"
        override val defaultLabel: String = "Checked out"
    }

    data object Unknown : AttendanceUiState {
        override val tone: StatusTone = StatusTone.Warning
        override val iconKey: String = "attendance_unknown"
        override val labelHook: String = "attendance.unknown"
        override val defaultLabel: String = "Attendance status unknown"
    }
}
