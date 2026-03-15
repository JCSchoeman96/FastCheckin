package za.co.voelgoed.fastcheck.feature.scanning.analysis

import com.google.mlkit.vision.barcode.BarcodeScanner
import com.google.mlkit.vision.common.InputImage
import java.time.Clock
import javax.inject.Inject
import javax.inject.Singleton
import za.co.voelgoed.fastcheck.feature.scanning.domain.DecodedBarcode

@Singleton
class MlKitBarcodeScannerEngine @Inject constructor(
    private val barcodeScanner: BarcodeScanner,
    private val clock: Clock
) : BarcodeScannerEngine {
    override fun process(
        image: InputImage,
        onSuccess: (List<DecodedBarcode>) -> Unit,
        onFailure: (Exception) -> Unit
    ) {
        barcodeScanner.process(image)
            .addOnSuccessListener { barcodes ->
                onSuccess(
                    barcodes.map { barcode ->
                        DecodedBarcode(
                            rawValue = barcode.rawValue,
                            capturedAtEpochMillis = clock.millis()
                        )
                    }
                )
            }
            .addOnFailureListener(onFailure)
    }
}
