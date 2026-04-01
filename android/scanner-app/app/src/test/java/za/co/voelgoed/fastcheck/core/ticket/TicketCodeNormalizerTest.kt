package za.co.voelgoed.fastcheck.core.ticket

import com.google.common.truth.Truth.assertThat
import org.junit.Test

class TicketCodeNormalizerTest {
    @Test
    fun keepsAlreadyCanonicalTicketCodeUnchanged() {
        assertThat(TicketCodeNormalizer.normalizeOrNull("VG-101")).isEqualTo("VG-101")
    }

    @Test
    fun trimsProvenScannerBoundaryWhitespace() {
        assertThat(TicketCodeNormalizer.normalizeOrNull(" \tVG-101\r\n")).isEqualTo("VG-101")
    }

    @Test
    fun rejectsBlankValueAfterCanonicalization() {
        assertThat(TicketCodeNormalizer.normalizeOrNull(" \t\r\n ")).isNull()
    }

    @Test
    fun rejectsNonAsciiWhitespaceOnlyValueAfterBoundaryTrim() {
        assertThat(TicketCodeNormalizer.normalizeOrNull("\u00A0")).isNull()
    }

    @Test
    fun leavesUnsupportedStructuredPayloadLiteralAfterBoundaryTrim() {
        val rawValue = "\r\nhttps://scan.voelgoed.co.za/tickets/VG-101 \t"

        assertThat(TicketCodeNormalizer.normalizeOrNull(rawValue))
            .isEqualTo("https://scan.voelgoed.co.za/tickets/VG-101")
    }
}
