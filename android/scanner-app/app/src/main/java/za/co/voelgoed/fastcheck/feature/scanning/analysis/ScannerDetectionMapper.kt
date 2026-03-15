package za.co.voelgoed.fastcheck.feature.scanning.analysis

import com.google.mlkit.vision.barcode.common.Barcode
import javax.inject.Inject
import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerDetection

class ScannerDetectionMapper @Inject constructor() {
    fun map(
        barcode: Barcode,
        capturedAtEpochMillis: Long
    ): ScannerDetection? =
        map(
            rawValue = barcode.rawValue,
            bounds = barcode.boundingBox,
            format = barcode.format,
            capturedAtEpochMillis = capturedAtEpochMillis
        )

    internal fun map(
        rawValue: String?,
        bounds: android.graphics.Rect?,
        format: Int,
        capturedAtEpochMillis: Long
    ): ScannerDetection? {
        val resolvedRawValue = rawValue?.takeUnless(String::isBlank) ?: return null

        return ScannerDetection(
            rawValue = resolvedRawValue,
            bounds = bounds?.toScannerBounds(),
            format = format,
            capturedAtEpochMillis = capturedAtEpochMillis
        )
    }

    private fun android.graphics.Rect.toScannerBounds(): ScannerDetection.Bounds =
        ScannerDetection.Bounds(
            left = left,
            top = top,
            right = right,
            bottom = bottom
        )
}
