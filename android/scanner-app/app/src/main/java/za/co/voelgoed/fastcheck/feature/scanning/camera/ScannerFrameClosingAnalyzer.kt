package za.co.voelgoed.fastcheck.feature.scanning.camera

import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import javax.inject.Inject

class ScannerFrameClosingAnalyzer(
    private val onFrameClosed: (() -> Unit)? = null
) : ImageAnalysis.Analyzer {
    @Inject
    constructor() : this(onFrameClosed = null)

    override fun analyze(image: ImageProxy) {
        try {
            onFrameClosed?.invoke()
        } finally {
            image.close()
        }
    }
}
