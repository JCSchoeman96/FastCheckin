package za.co.voelgoed.fastcheck.feature.scanning.analysis

import com.google.common.truth.Truth.assertThat
import com.google.mlkit.vision.barcode.common.Barcode
import org.junit.Test

class ScannerFormatConfigTest {
    @Test
    fun fastCheckDefaultUsesProvisionalRestrictedAllowlist() {
        val config = ScannerFormatConfig.fastCheckDefault

        assertThat(config.policyName).isEqualTo("fastcheck-provisional")
        assertThat(config.isProvisional).isTrue()
        assertThat(config.allowedFormats)
            .containsExactly(
                Barcode.FORMAT_QR_CODE,
                Barcode.FORMAT_CODE_128,
                Barcode.FORMAT_PDF417
            )
            .inOrder()
    }

    @Test
    fun formatConfigRequiresAtLeastOneAllowedFormat() {
        val exception =
            runCatching {
                ScannerFormatConfig(
                    policyName = "invalid",
                    allowedFormats = emptyList(),
                    isProvisional = true
                )
            }.exceptionOrNull()

        assertThat(exception).isInstanceOf(IllegalArgumentException::class.java)
        assertThat(exception).hasMessageThat().contains("must not be empty")
    }
}
