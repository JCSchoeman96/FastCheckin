package za.co.voelgoed.fastcheck.domain.model

data class ScannerSession(
    val eventId: Long,
    val eventName: String,
    val eventShortname: String? = null,
    val expiresInSeconds: Int,
    val authenticatedAtEpochMillis: Long,
    val expiresAtEpochMillis: Long
)
