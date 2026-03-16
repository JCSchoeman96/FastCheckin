package za.co.voelgoed.fastcheck.feature.scanning.domain

import za.co.voelgoed.fastcheck.domain.model.ScanDirection

data class ScannerCaptureConfig(
    val direction: ScanDirection = ScanDirection.IN,
    val operatorName: String = "Camera Scanner",
    val entranceName: String = "Camera Preview"
) {
    companion object {
        val default: ScannerCaptureConfig = ScannerCaptureConfig()
    }
}
