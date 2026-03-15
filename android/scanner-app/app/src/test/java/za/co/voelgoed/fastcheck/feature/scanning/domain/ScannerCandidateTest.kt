package za.co.voelgoed.fastcheck.feature.scanning.domain

import com.google.common.truth.Truth.assertThat
import org.junit.Test

class ScannerCandidateTest {
    @Test
    fun fromDecodedPreservesNonBlankRawValueWithoutTrimming() {
        val candidate =
            ScannerCandidate.fromDecoded(
                DecodedBarcode(
                    rawValue = "  VG-900  ",
                    capturedAtEpochMillis = 44L
                )
            )

        assertThat(candidate).isEqualTo(ScannerCandidate("  VG-900  ", 44L))
    }

    @Test
    fun fromDecodedDropsNullAndBlankValues() {
        assertThat(ScannerCandidate.fromDecoded(DecodedBarcode(null, 1L))).isNull()
        assertThat(ScannerCandidate.fromDecoded(DecodedBarcode("   ", 2L))).isNull()
    }
}
