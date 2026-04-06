package za.co.voelgoed.fastcheck.data.repository

import javax.inject.Inject
import javax.inject.Singleton
import za.co.voelgoed.fastcheck.domain.model.PaymentStatusDecision

@Singleton
class PaymentStatusRuleMapper @Inject constructor() {
    fun map(rawStatus: String?): PaymentStatusDecision {
        val normalized =
            rawStatus
                ?.trim()
                ?.lowercase()
                ?.takeIf { it.isNotBlank() }
                ?: return PaymentStatusDecision.UNKNOWN

        return when (normalized) {
            in allowedStatuses -> PaymentStatusDecision.ALLOWED
            in blockedStatuses -> PaymentStatusDecision.BLOCKED
            else -> PaymentStatusDecision.UNKNOWN
        }
    }

    private companion object {
        val allowedStatuses: Set<String> =
            setOf("completed", "paid", "complete")

        val blockedStatuses: Set<String> =
            setOf("failed", "cancelled", "canceled", "refunded", "unpaid", "voided")
    }
}
