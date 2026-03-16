package za.co.voelgoed.fastcheck.feature.scanning.analysis

import com.google.mlkit.vision.barcode.BarcodeScanner
import com.google.mlkit.vision.common.InputImage
import java.time.Clock
import javax.inject.Inject
import javax.inject.Singleton
import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerDetection

@Singleton
class MlKitBarcodeScannerEngine @Inject constructor(
    private val barcodeScanner: BarcodeScanner,
    private val clock: Clock,
    private val scannerDetectionMapper: ScannerDetectionMapper
) : BarcodeScannerEngine {
    override fun process(
        image: InputImage,
        onSuccess: (List<ScannerDetection>) -> Unit,
        onFailure: (Exception) -> Unit
    ) {
        barcodeScanner.process(image)
            .addOnSuccessListener { barcodes ->
                val capturedAtEpochMillis = clock.millis()
                onSuccess(
                    barcodes.mapNotNull { barcode ->
                        scannerDetectionMapper.map(barcode, capturedAtEpochMillis)
                    }
                )
            }
            .addOnFailureListener(onFailure)
    }
}
