package za.co.voelgoed.fastcheck.core.designsystem.semantic

import com.google.common.truth.Truth.assertThat
import org.junit.Test
import za.co.voelgoed.fastcheck.domain.model.AttendeeRecord

class PaymentUiStateMappersTest {
    @Test
    fun completedMapsToPaid() {
        val state =
            AttendeeRecord(
                id = 1,
                eventId = 2,
                ticketCode = "VG-1",
                fullName = "Ada Lovelace",
                ticketType = null,
                paymentStatus = "completed",
                isCurrentlyInside = false,
                updatedAt = null
            ).toPaymentUiState()

        assertThat(state).isEqualTo(PaymentUiState.Paid)
    }

    @Test
    fun paidMapsToPaid() {
        assertThat("paid".toPaymentUiState()).isEqualTo(PaymentUiState.Paid)
    }

    @Test
    fun pendingStatusesMapToPending() {
        assertThat("pending".toPaymentUiState()).isEqualTo(PaymentUiState.Pending)
        assertThat("processing".toPaymentUiState()).isEqualTo(PaymentUiState.Pending)
        assertThat("on hold".toPaymentUiState()).isEqualTo(PaymentUiState.Pending)
        assertThat("on_hold".toPaymentUiState()).isEqualTo(PaymentUiState.Pending)
        assertThat("unpaid".toPaymentUiState()).isEqualTo(PaymentUiState.Pending)
    }

    @Test
    fun invalidStatusesMapToNotValid() {
        assertThat("refunded".toPaymentUiState()).isEqualTo(PaymentUiState.NotValid)
        assertThat("cancelled".toPaymentUiState()).isEqualTo(PaymentUiState.NotValid)
        assertThat("canceled".toPaymentUiState()).isEqualTo(PaymentUiState.NotValid)
        assertThat("voided".toPaymentUiState()).isEqualTo(PaymentUiState.NotValid)
        assertThat("failed".toPaymentUiState()).isEqualTo(PaymentUiState.NotValid)
    }

    @Test
    fun blankOrUnknownPaymentStatusMapsToUnknown() {
        assertThat(" ".toPaymentUiState()).isEqualTo(PaymentUiState.Unknown)
        assertThat(null.toPaymentUiState()).isEqualTo(PaymentUiState.Unknown)
        assertThat("not-a-real-status".toPaymentUiState()).isEqualTo(PaymentUiState.Unknown)
    }
}
