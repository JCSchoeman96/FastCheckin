package za.co.voelgoed.fastcheck.data.repository

import com.google.common.truth.Truth.assertThat
import org.junit.Test
import za.co.voelgoed.fastcheck.data.local.AttendeeEntity
import za.co.voelgoed.fastcheck.data.local.LocalAdmissionOverlayEntity
import za.co.voelgoed.fastcheck.domain.model.EventAdmissionMode

class OverlayCatchUpPolicyTest {
    private val policy = OverlayCatchUpPolicy()

    @Test
    fun syncedCheckInWithinSkewToleranceCountsAsCaughtUp() {
        val caughtUp =
            policy.hasSyncedBaseCaughtUp(
                attendee = attendee(checkedInAt = "2026-04-06T10:00:30Z"),
                overlay = overlay(overlayScannedAt = "2026-04-06T10:02:00Z"),
                admissionMode = EventAdmissionMode.SESSION
            )

        assertThat(caughtUp).isTrue()
    }

    @Test
    fun olderSyncedCheckInBeyondSkewToleranceKeepsOverlayActive() {
        val caughtUp =
            policy.hasSyncedBaseCaughtUp(
                attendee = attendee(checkedInAt = "2026-04-06T09:57:00Z"),
                overlay = overlay(overlayScannedAt = "2026-04-06T10:00:00Z"),
                admissionMode = EventAdmissionMode.SESSION
            )

        assertThat(caughtUp).isFalse()
    }

    @Test
    fun turnstileBaseCatchesUpWithoutAnInsideFlag() {
        val caughtUp =
            policy.hasSyncedBaseCaughtUp(
                attendee = attendee(checkedInAt = "2026-04-06T10:00:30Z", isCurrentlyInside = false),
                overlay = overlay(overlayScannedAt = "2026-04-06T10:02:00Z"),
                admissionMode = EventAdmissionMode.TURNSTILE
            )

        assertThat(caughtUp).isTrue()
    }

    private fun attendee(checkedInAt: String?, isCurrentlyInside: Boolean = true): AttendeeEntity =
        AttendeeEntity(
            id = 7L,
            eventId = 42L,
            ticketCode = "VG-007",
            firstName = "Jane",
            lastName = "Doe",
            email = "jane@example.com",
            ticketType = "VIP",
            allowedCheckins = 1,
            checkinsRemaining = 0,
            paymentStatus = "completed",
            isCurrentlyInside = isCurrentlyInside,
            checkedInAt = checkedInAt,
            checkedOutAt = null,
            updatedAt = "2026-04-06T10:05:00Z"
        )

    private fun overlay(overlayScannedAt: String): LocalAdmissionOverlayEntity =
        LocalAdmissionOverlayEntity(
            eventId = 42L,
            attendeeId = 7L,
            ticketCode = "VG-007",
            idempotencyKey = "idem-007",
            state = "CONFIRMED_LOCAL_UNSYNCED",
            createdAtEpochMillis = 1L,
            overlayScannedAt = overlayScannedAt,
            expectedRemainingAfterOverlay = 0,
            operatorName = "Op",
            entranceName = "Main"
        )
}
