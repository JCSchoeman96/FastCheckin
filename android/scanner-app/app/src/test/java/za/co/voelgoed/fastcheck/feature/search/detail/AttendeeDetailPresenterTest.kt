package za.co.voelgoed.fastcheck.feature.search.detail

import com.google.common.truth.Truth.assertThat
import org.junit.Test
import za.co.voelgoed.fastcheck.core.designsystem.semantic.StatusTone
import za.co.voelgoed.fastcheck.domain.model.AttendeeDetailRecord
import za.co.voelgoed.fastcheck.domain.model.LocalAdmissionOverlayState
import za.co.voelgoed.fastcheck.feature.search.detail.model.ManualActionUiState

class AttendeeDetailPresenterTest {
    private val presenter = AttendeeDetailPresenter()

    private fun record(
        overlay: String? = null,
        inside: Boolean = false,
        conflictMessage: String? = null
    ): AttendeeDetailRecord =
        AttendeeDetailRecord(
            id = 1L,
            eventId = 5L,
            ticketCode = "VG-1",
            firstName = "A",
            lastName = "B",
            displayName = "A B",
            email = "a@b.com",
            ticketType = "G",
            paymentStatus = "completed",
            isCurrentlyInside = inside,
            checkedInAt = null,
            checkedOutAt = null,
            allowedCheckins = 1,
            checkinsRemaining = 1,
            updatedAt = "2026-04-06T10:00:00Z",
            localOverlayState = overlay,
            localConflictReasonCode = null,
            localConflictMessage = conflictMessage,
            localOverlayScannedAt = null,
            expectedRemainingAfterOverlay = null
        )

    @Test
    fun presentsLocalTruthNoteForOperatorCache() {
        val ui = presenter.present(record(), ManualActionUiState())

        assertThat(ui.localTruthNote).contains("local attendee cache")
    }

    @Test
    fun duplicateConflictShowsTitleAndWarningAttendance() {
        val ui =
            presenter.present(
                record(overlay = LocalAdmissionOverlayState.CONFLICT_DUPLICATE.name, conflictMessage = "dup msg"),
                ManualActionUiState()
            )

        assertThat(ui.conflictTitle).isEqualTo("Duplicate conflict")
        assertThat(ui.attendanceStatusLabel).isEqualTo("Conflict blocks local admission")
        assertThat(ui.attendanceStatusTone).isEqualTo(StatusTone.Warning)
        assertThat(ui.conflictMessage).isEqualTo("dup msg")
    }
}
