package za.co.voelgoed.fastcheck.feature.scanning.analysis

import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import com.google.mlkit.vision.common.InputImage
import javax.inject.Inject
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import za.co.voelgoed.fastcheck.core.common.AppDispatchers
import za.co.voelgoed.fastcheck.feature.scanning.domain.DecodedBarcode
import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerDetection

class MlKitBarcodeFrameAnalyzer @Inject constructor(
    private val barcodeScannerEngine: BarcodeScannerEngine,
    private val scannerFrameGate: ScannerFrameGate,
    private val decodedBarcodeHandler: DecodedBarcodeHandler,
    appDispatchers: AppDispatchers
) : ImageAnalysis.Analyzer {
    private val scope = CoroutineScope(SupervisorJob() + appDispatchers.default)

    override fun analyze(imageProxy: ImageProxy) {
        val mediaImage = imageProxy.image

        if (mediaImage == null) {
            imageProxy.close()
            return
        }

        val inputImage =
            InputImage.fromMediaImage(mediaImage, imageProxy.imageInfo.rotationDegrees)

        barcodeScannerEngine.process(
            image = inputImage,
            onSuccess = { detections ->
                deliverDetections(detections, imageProxy)
            },
            onFailure = {
                imageProxy.close()
            }
        )
    }

    internal fun deliverDetections(
        detections: List<ScannerDetection>,
        imageProxy: ImageProxy
    ) {
        val decodedBarcode =
            detections.firstOrNull { detection -> scannerFrameGate.tryAdmit(detection) }
                ?.toDecodedBarcode()

        imageProxy.close()

        if (decodedBarcode != null) {
            scope.launch {
                decodedBarcodeHandler.onDecoded(decodedBarcode)
            }
        }
    }

    private fun ScannerDetection.toDecodedBarcode(): DecodedBarcode =
        DecodedBarcode(
            rawValue = rawValue,
            capturedAtEpochMillis = capturedAtEpochMillis
        )
}
