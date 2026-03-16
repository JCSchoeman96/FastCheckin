package za.co.voelgoed.fastcheck.feature.scanning.analysis

import com.google.mlkit.vision.barcode.BarcodeScannerOptions
import com.google.mlkit.vision.barcode.common.Barcode

data class ScannerFormatConfig(
    val policyName: String,
    val allowedFormats: List<Int>,
    val isProvisional: Boolean
) {
    init {
        require(allowedFormats.isNotEmpty()) {
            "ScannerFormatConfig.allowedFormats must not be empty."
        }
    }

    fun toBarcodeScannerOptions(): BarcodeScannerOptions {
        val primaryFormat = allowedFormats.first()
        val additionalFormats = allowedFormats.drop(1).toIntArray()

        return BarcodeScannerOptions.Builder()
            .setBarcodeFormats(primaryFormat, *additionalFormats)
            .build()
    }

    companion object {
        // Tighten this allowlist once real FastCheck/Tickera ticket samples
        // confirm the emitted barcode symbology.
        val fastCheckDefault =
            ScannerFormatConfig(
                policyName = "fastcheck-provisional",
                allowedFormats =
                    listOf(
                        Barcode.FORMAT_QR_CODE,
                        Barcode.FORMAT_CODE_128,
                        Barcode.FORMAT_PDF417
                    ),
                isProvisional = true
            )
    }
}
