package za.co.voelgoed.fastcheck.feature.scanning.analysis

interface DecodedBarcodeHandler {
    suspend fun onDecoded(rawValue: String)
}
