package za.co.voelgoed.fastcheck.feature.scanning.analysis

import com.google.mlkit.vision.common.InputImage
import za.co.voelgoed.fastcheck.feature.scanning.domain.DecodedBarcode

interface BarcodeScannerEngine {
    fun process(
        image: InputImage,
        onSuccess: (List<DecodedBarcode>) -> Unit,
        onFailure: (Exception) -> Unit
    )
}
