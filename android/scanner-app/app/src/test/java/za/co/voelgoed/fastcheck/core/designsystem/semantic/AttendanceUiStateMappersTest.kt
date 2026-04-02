package za.co.voelgoed.fastcheck.core.designsystem.semantic

import com.google.common.truth.Truth.assertThat
import org.junit.Test

class AttendanceUiStateMappersTest {
    @Test
    fun missingTimestampsMapsToNotCheckedIn() {
        assertThat(
            toAttendanceUiState(
                checkedInAt = null,
                checkedOutAt = null,
                isCurrentlyInside = false
            )
        ).isEqualTo(AttendanceUiState.NotCheckedIn)
    }

    @Test
    fun checkedInTimestampMapsToCheckedIn() {
        assertThat(
            toAttendanceUiState(
                checkedInAt = "2026-03-13T08:00:00Z",
                checkedOutAt = null,
                isCurrentlyInside = false
            )
        ).isEqualTo(AttendanceUiState.CheckedIn)
    }

    @Test
    fun checkedOutWinsOverCheckedIn() {
        assertThat(
            toAttendanceUiState(
                checkedInAt = "2026-03-13T08:00:00Z",
                checkedOutAt = "2026-03-13T09:00:00Z",
                isCurrentlyInside = false
            )
        ).isEqualTo(AttendanceUiState.CheckedOut)
    }

    @Test
    fun currentlyInsideWinsWhenNoCheckedOutExists() {
        assertThat(
            toAttendanceUiState(
                checkedInAt = "2026-03-13T08:00:00Z",
                checkedOutAt = null,
                isCurrentlyInside = true
            )
        ).isEqualTo(AttendanceUiState.CurrentlyInside)
    }

    @Test
    fun contradictoryCheckedOutAndCurrentlyInsideMapsToUnknown() {
        assertThat(
            toAttendanceUiState(
                checkedInAt = "2026-03-13T08:00:00Z",
                checkedOutAt = "2026-03-13T09:00:00Z",
                isCurrentlyInside = true
            )
        ).isEqualTo(AttendanceUiState.Unknown)
    }
}
