package za.co.voelgoed.fastcheck.feature.scanning.domain

data class ScannerDetection(
    val rawValue: String,
    val bounds: Bounds?,
    val format: Int,
    val capturedAtEpochMillis: Long
) {
    data class Bounds(
        val left: Int,
        val top: Int,
        val right: Int,
        val bottom: Int
    )
}
