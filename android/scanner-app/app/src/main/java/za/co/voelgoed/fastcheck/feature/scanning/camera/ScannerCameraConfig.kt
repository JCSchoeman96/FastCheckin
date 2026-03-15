package za.co.voelgoed.fastcheck.feature.scanning.camera

import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis

object ScannerCameraConfig {
    const val backpressureStrategy: Int = ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST

    val cameraSelector: CameraSelector = CameraSelector.DEFAULT_BACK_CAMERA
}
