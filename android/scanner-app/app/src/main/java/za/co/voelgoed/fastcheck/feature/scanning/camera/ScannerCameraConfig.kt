package za.co.voelgoed.fastcheck.feature.scanning.camera

import android.util.Size
import androidx.camera.core.AspectRatio
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis

data class ScannerCameraConfig(
    val lensFacing: Int = CameraSelector.LENS_FACING_BACK,
    val aspectRatio: Int = AspectRatio.RATIO_4_3,
    val targetResolution: Size? = null,
    val backpressureStrategy: Int = ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST
) {
    fun cameraSelector(): CameraSelector =
        CameraSelector.Builder()
            .requireLensFacing(lensFacing)
            .build()

    companion object {
        val default: ScannerCameraConfig = ScannerCameraConfig()
    }
}
