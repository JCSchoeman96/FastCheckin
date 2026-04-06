package za.co.voelgoed.fastcheck.data.repository

import java.time.DateTimeException
import java.time.Instant
import javax.inject.Inject
import za.co.voelgoed.fastcheck.data.local.AttendeeEntity
import za.co.voelgoed.fastcheck.data.local.LocalAdmissionOverlayEntity
import za.co.voelgoed.fastcheck.domain.policy.AdmissionRuntimePolicy

class OverlayCatchUpPolicy @Inject constructor() {
    fun hasSyncedBaseCaughtUp(
        attendee: AttendeeEntity,
        overlay: LocalAdmissionOverlayEntity
    ): Boolean {
        if (attendee.eventId != overlay.eventId) {
            return false
        }

        val identityMatches =
            attendee.id == overlay.attendeeId ||
                (attendee.ticketCode == overlay.ticketCode && attendee.eventId == overlay.eventId)

        if (!identityMatches) {
            return false
        }

        if (!attendee.isCurrentlyInside) {
            return false
        }

        if (attendee.checkinsRemaining > overlay.expectedRemainingAfterOverlay) {
            return false
        }

        val syncedCheckedInAt = parseInstantOrNull(attendee.checkedInAt) ?: return false
        val overlayScannedAt = parseInstantOrNull(overlay.overlayScannedAt) ?: return false
        val lowerBound = overlayScannedAt.minus(AdmissionRuntimePolicy.ADMISSION_TIME_SKEW_TOLERANCE)

        return !syncedCheckedInAt.isBefore(lowerBound)
    }

    private fun parseInstantOrNull(value: String?): Instant? =
        value?.let {
            try {
                Instant.parse(it)
            } catch (_: DateTimeException) {
                null
            }
        }
}
