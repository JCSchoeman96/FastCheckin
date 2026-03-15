package za.co.voelgoed.fastcheck.feature.scanning.domain

import za.co.voelgoed.fastcheck.domain.model.ScanDirection

object ScannerCaptureDefaults {
    val direction: ScanDirection = ScanDirection.IN

    const val operatorName: String = "Camera Scanner"
    const val entranceName: String = "Camera Preview"
}
