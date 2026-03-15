package za.co.voelgoed.fastcheck.domain.model

data class PendingScan(
    val localId: Long = 0,
    val eventId: Long,
    val ticketCode: String,
    val idempotencyKey: String,
    val createdAt: Long,
    val scannedAt: String,
    val direction: ScanDirection,
    val entranceName: String,
    val operatorName: String
)
