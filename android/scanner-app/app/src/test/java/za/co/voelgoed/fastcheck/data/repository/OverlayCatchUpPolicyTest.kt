package za.co.voelgoed.fastcheck.data.repository

import com.google.common.truth.Truth.assertThat
import org.junit.Test
import za.co.voelgoed.fastcheck.data.local.AttendeeEntity
import za.co.voelgoed.fastcheck.data.local.LocalAdmissionOverlayEntity

class OverlayCatchUpPolicyTest {
    private val policy = OverlayCatchUpPolicy()

    @Test
    fun syncedCheckInWithinSkewToleranceCountsAsCaughtUp() {
        val caughtUp =
            policy.hasSyncedBaseCaughtUp(
                attendee = attendee(checkedInAt = "2026-04-06T10:00:30Z"),
                overlay = overlay(overlayScannedAt = "2026-04-06T10:02:00Z")
            )

        assertThat(caughtUp).isTrue()
    }

    @Test
    fun olderSyncedCheckInBeyondSkewToleranceKeepsOverlayActive() {
        val caughtUp =
            policy.hasSyncedBaseCaughtUp(
                attendee = attendee(checkedInAt = "2026-04-06T09:57:00Z"),
                overlay = overlay(overlayScannedAt = "2026-04-06T10:00:00Z")
            )

        assertThat(caughtUp).isFalse()
    }

    private fun attendee(checkedInAt: String?): AttendeeEntity =
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
            isCurrentlyInside = true,
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
