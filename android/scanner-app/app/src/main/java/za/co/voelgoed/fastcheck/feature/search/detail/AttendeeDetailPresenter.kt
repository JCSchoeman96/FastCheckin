package za.co.voelgoed.fastcheck.feature.search.detail

import za.co.voelgoed.fastcheck.core.designsystem.semantic.StatusTone
import za.co.voelgoed.fastcheck.domain.model.AttendeeDetailRecord
import za.co.voelgoed.fastcheck.domain.model.LocalAdmissionOverlayState
import za.co.voelgoed.fastcheck.feature.search.detail.model.AttendeeDetailUiState
import za.co.voelgoed.fastcheck.feature.search.detail.model.ManualActionUiState

class AttendeeDetailPresenter {
    fun present(
        record: AttendeeDetailRecord,
        manualActionUiState: ManualActionUiState
    ): AttendeeDetailUiState {
        val conflictTitle =
            when (record.localOverlayState) {
                LocalAdmissionOverlayState.CONFLICT_DUPLICATE.name -> "Duplicate conflict"
                LocalAdmissionOverlayState.CONFLICT_REJECTED.name -> "Rejected conflict"
                else -> null
            }

        val attendanceTone =
            when {
                record.localOverlayState in LocalAdmissionOverlayState.conflictStates.map { it.name } ->
                    StatusTone.Warning
                record.isCurrentlyInside ->
                    StatusTone.Success
                else ->
                    StatusTone.Neutral
            }

        return AttendeeDetailUiState(
            displayName = record.displayName,
            ticketCode = record.ticketCode,
            email = record.email,
            ticketType = record.ticketType,
            paymentStatus = record.paymentStatus,
            attendanceStatusLabel =
                when {
                    record.localOverlayState in LocalAdmissionOverlayState.conflictStates.map { it.name } ->
                        "Conflict blocks local admission"
                    record.isCurrentlyInside ->
                        "Currently inside"
                    else ->
                        "Not currently inside"
                },
            attendanceStatusTone = attendanceTone,
            allowedCheckinsLabel = "Allowed check-ins: ${record.allowedCheckins}",
            remainingCheckinsLabel = "Check-ins remaining: ${record.checkinsRemaining}",
            checkedInAt = record.checkedInAt,
            checkedOutAt = record.checkedOutAt,
            localTruthNote = "This detail reflects the local attendee cache plus any unresolved local gate state on this device.",
            conflictTitle = conflictTitle,
            conflictMessage = record.localConflictMessage,
            manualActionUiState = manualActionUiState
        )
    }
}
