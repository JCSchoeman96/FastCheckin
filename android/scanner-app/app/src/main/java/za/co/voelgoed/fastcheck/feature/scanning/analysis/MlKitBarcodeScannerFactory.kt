package za.co.voelgoed.fastcheck.feature.scanning.analysis

import com.google.mlkit.vision.barcode.BarcodeScanning
import com.google.mlkit.vision.barcode.BarcodeScanner
import javax.inject.Inject

class MlKitBarcodeScannerFactory @Inject constructor(
    private val formatConfig: ScannerFormatConfig
) {
    fun create(): BarcodeScanner {
        val options = formatConfig.toBarcodeScannerOptions()

        return BarcodeScanning.getClient(options)
    }
}
