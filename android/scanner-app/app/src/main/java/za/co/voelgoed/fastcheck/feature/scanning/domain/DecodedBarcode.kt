package za.co.voelgoed.fastcheck.feature.scanning.domain

data class DecodedBarcode(
    val rawValue: String?,
    val capturedAtEpochMillis: Long
)
