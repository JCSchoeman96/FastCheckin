package za.co.voelgoed.fastcheck.feature.scanning.domain

data class ScannerCandidate(
    val rawValue: String,
    val capturedAtEpochMillis: Long
) {
    companion object {
        fun fromDecoded(decodedBarcode: DecodedBarcode): ScannerCandidate? {
            val rawValue = decodedBarcode.rawValue?.trim()?.takeIf { value -> value.isNotEmpty() }
                ?: return null

            return ScannerCandidate(
                rawValue = rawValue,
                capturedAtEpochMillis = decodedBarcode.capturedAtEpochMillis
            )
        }
    }
}
