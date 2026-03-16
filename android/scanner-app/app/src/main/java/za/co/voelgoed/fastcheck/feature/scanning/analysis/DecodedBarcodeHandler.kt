package za.co.voelgoed.fastcheck.feature.scanning.analysis

import za.co.voelgoed.fastcheck.feature.scanning.domain.DecodedBarcode

interface DecodedBarcodeHandler {
    suspend fun onDecoded(decodedBarcode: DecodedBarcode)
}
