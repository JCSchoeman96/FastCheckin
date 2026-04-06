package za.co.voelgoed.fastcheck.data.repository

import com.google.common.truth.Truth.assertThat
import org.junit.Test
import za.co.voelgoed.fastcheck.domain.model.PaymentStatusDecision

class PaymentStatusRuleMapperTest {
    private val mapper = PaymentStatusRuleMapper()

    @Test
    fun mapsKnownAllowedStatuses() {
        assertThat(mapper.map("completed")).isEqualTo(PaymentStatusDecision.ALLOWED)
        assertThat(mapper.map("paid")).isEqualTo(PaymentStatusDecision.ALLOWED)
        assertThat(mapper.map("complete")).isEqualTo(PaymentStatusDecision.ALLOWED)
    }

    @Test
    fun mapsKnownBlockedStatuses() {
        assertThat(mapper.map("failed")).isEqualTo(PaymentStatusDecision.BLOCKED)
        assertThat(mapper.map("cancelled")).isEqualTo(PaymentStatusDecision.BLOCKED)
        assertThat(mapper.map("canceled")).isEqualTo(PaymentStatusDecision.BLOCKED)
        assertThat(mapper.map("refunded")).isEqualTo(PaymentStatusDecision.BLOCKED)
        assertThat(mapper.map("unpaid")).isEqualTo(PaymentStatusDecision.BLOCKED)
        assertThat(mapper.map("voided")).isEqualTo(PaymentStatusDecision.BLOCKED)
    }

    @Test
    fun mapsUnknownStatusesToUnknown() {
        assertThat(mapper.map("pending")).isEqualTo(PaymentStatusDecision.UNKNOWN)
        assertThat(mapper.map("hold")).isEqualTo(PaymentStatusDecision.UNKNOWN)
    }

    @Test
    fun mapsNullAndBlankToUnknown() {
        assertThat(mapper.map(null)).isEqualTo(PaymentStatusDecision.UNKNOWN)
        assertThat(mapper.map("")).isEqualTo(PaymentStatusDecision.UNKNOWN)
        assertThat(mapper.map("   ")).isEqualTo(PaymentStatusDecision.UNKNOWN)
    }

    @Test
    fun normalizationIsCaseInsensitiveAndTrims() {
        assertThat(mapper.map("  PAID  ")).isEqualTo(PaymentStatusDecision.ALLOWED)
        assertThat(mapper.map("FAILED")).isEqualTo(PaymentStatusDecision.BLOCKED)
        assertThat(mapper.map("CaNcElLeD")).isEqualTo(PaymentStatusDecision.BLOCKED)
    }

    @Test
    fun sameInputMapsDeterministically() {
        val first = mapper.map("weird")
        repeat(5) {
            assertThat(mapper.map("weird")).isEqualTo(first)
        }
    }
}
