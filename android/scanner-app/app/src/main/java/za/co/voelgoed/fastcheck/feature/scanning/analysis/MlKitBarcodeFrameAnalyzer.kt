package za.co.voelgoed.fastcheck.feature.scanning.analysis

import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import com.google.mlkit.vision.common.InputImage
import javax.inject.Inject
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import za.co.voelgoed.fastcheck.core.common.AppDispatchers
import za.co.voelgoed.fastcheck.core.common.ScannerRuntimeLogger
import za.co.voelgoed.fastcheck.feature.scanning.domain.DecodedBarcode

class MlKitBarcodeFrameAnalyzer @Inject constructor(
    private val barcodeScannerEngine: BarcodeScannerEngine,
    private val decodedBarcodeHandler: DecodedBarcodeHandler,
    appDispatchers: AppDispatchers
) : ImageAnalysis.Analyzer {
    private val scope = CoroutineScope(SupervisorJob() + appDispatchers.default)

    override fun analyze(imageProxy: ImageProxy) {
        ScannerRuntimeLogger.d(LOG_TAG, "frame_received rotation=${imageProxy.imageInfo.rotationDegrees}")
        decodedBarcodeHandler.onDecodeDiagnostic(DecodeDiagnostic.FrameReceived)
        val mediaImage = imageProxy.image

        if (mediaImage == null) {
            ScannerRuntimeLogger.w(LOG_TAG, "frame_dropped media_image_missing")
            decodedBarcodeHandler.onDecodeDiagnostic(DecodeDiagnostic.MediaImageMissing)
            imageProxy.close()
            return
        }

        val inputImage =
            InputImage.fromMediaImage(mediaImage, imageProxy.imageInfo.rotationDegrees)

        barcodeScannerEngine.process(
            image = inputImage,
            onSuccess = { decodedBarcodes ->
                ScannerRuntimeLogger.d(LOG_TAG, "decode_success count=${decodedBarcodes.size}")
                deliverDecodedBarcodes(decodedBarcodes, imageProxy)
            },
            onFailure = { error ->
                ScannerRuntimeLogger.w(LOG_TAG, "decode_failure message=${error.message}")
                decodedBarcodeHandler.onDecodeDiagnostic(DecodeDiagnostic.DecodeFailure)
                imageProxy.close()
            }
        )
    }

    internal fun deliverDecodedBarcodes(
        decodedBarcodes: List<DecodedBarcode>,
        imageProxy: ImageProxy
    ) {
        val rawValue = decodedBarcodes.firstNotNullOfOrNull { barcode ->
            barcode.rawValue?.takeIf { value -> value.isNotBlank() }
        }
        val hasUsableRawValue = rawValue != null
        ScannerRuntimeLogger.d(LOG_TAG, "decode_handoff_candidate hasUsableRawValue=$hasUsableRawValue")

        imageProxy.close()

        if (rawValue != null) {
            ScannerRuntimeLogger.i(LOG_TAG, "decode_handoff_started ticket=${maskTicketCode(rawValue)}")
            decodedBarcodeHandler.onDecodeDiagnostic(DecodeDiagnostic.DecodeHandoffStarted)
            scope.launch {
                decodedBarcodeHandler.onDecoded(rawValue)
            }
        } else {
            ScannerRuntimeLogger.d(LOG_TAG, "decode_no_usable_raw_value")
            decodedBarcodeHandler.onDecodeDiagnostic(DecodeDiagnostic.DecodeNoUsableRawValue)
        }
    }

    private fun maskTicketCode(rawValue: String): String {
        val trimmed = rawValue.trim()
        if (trimmed.length <= 4) return "***$trimmed"
        return "***${trimmed.takeLast(4)}"
    }

    private companion object {
        private const val LOG_TAG: String = "MlKitFrameAnalyzer"
    }
}
