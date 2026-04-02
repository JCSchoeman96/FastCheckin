package za.co.voelgoed.fastcheck.core.designsystem.semantic

import za.co.voelgoed.fastcheck.domain.model.AttendeeRecord

fun AttendeeRecord.toPaymentUiState(): PaymentUiState =
    paymentStatus.toPaymentUiState()

fun String?.toPaymentUiState(): PaymentUiState {
    val normalized =
        this
            ?.trim()
            ?.lowercase()
            ?.takeIf { it.isNotBlank() }
            ?: return PaymentUiState.Unknown

    return when (normalized) {
        "completed",
        "paid" -> PaymentUiState.Paid

        "pending",
        "processing",
        "on hold",
        "on_hold",
        "unpaid" -> PaymentUiState.Pending

        "refunded",
        "cancelled",
        "canceled",
        "voided",
        "failed" -> PaymentUiState.NotValid

        else -> PaymentUiState.Unknown
    }
}
