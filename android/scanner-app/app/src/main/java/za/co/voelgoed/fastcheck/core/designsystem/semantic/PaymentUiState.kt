/**
 * Semantic UI state for payment status presentation.
 *
 * Payment truth is projected from the current attendee record or raw runtime
 * status string. The model stays intentionally small and conservative.
 */
package za.co.voelgoed.fastcheck.core.designsystem.semantic

sealed interface PaymentUiState {
    val tone: StatusTone
    val iconKey: String
    val labelHook: String
    val defaultLabel: String

    data object Paid : PaymentUiState {
        override val tone: StatusTone = StatusTone.Success
        override val iconKey: String = "payment_paid"
        override val labelHook: String = "payment.paid"
        override val defaultLabel: String = "Paid"
    }

    data object Pending : PaymentUiState {
        override val tone: StatusTone = StatusTone.Warning
        override val iconKey: String = "payment_pending"
        override val labelHook: String = "payment.pending"
        override val defaultLabel: String = "Payment pending"
    }

    data object NotValid : PaymentUiState {
        override val tone: StatusTone = StatusTone.Destructive
        override val iconKey: String = "payment_not_valid"
        override val labelHook: String = "payment.not_valid"
        override val defaultLabel: String = "Payment not valid"
    }

    data object Unknown : PaymentUiState {
        override val tone: StatusTone = StatusTone.Muted
        override val iconKey: String = "payment_unknown"
        override val labelHook: String = "payment.unknown"
        override val defaultLabel: String = "Payment status unknown"
    }
}
