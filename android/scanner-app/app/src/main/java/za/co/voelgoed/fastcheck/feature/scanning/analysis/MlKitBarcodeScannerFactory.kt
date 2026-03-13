package za.co.voelgoed.fastcheck.feature.scanning.analysis

import com.google.mlkit.vision.barcode.BarcodeScannerOptions
import com.google.mlkit.vision.barcode.BarcodeScanning
import com.google.mlkit.vision.barcode.BarcodeScanner
import javax.inject.Inject

class MlKitBarcodeScannerFactory @Inject constructor() {
    fun create(): BarcodeScanner {
        // Keep the scanner unrestricted until the exact FastCheck/Tickera
        // barcode format set is confirmed.
        val options = BarcodeScannerOptions.Builder().build()

        return BarcodeScanning.getClient(options)
    }
}
