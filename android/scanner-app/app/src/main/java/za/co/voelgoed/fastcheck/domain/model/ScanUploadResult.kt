package za.co.voelgoed.fastcheck.domain.model

data class ScanUploadResult(
    val idempotencyKey: String,
    val status: String,
    val message: String
)
