package za.co.voelgoed.fastcheck.domain.model

/**
 * Stable reason codes for rows moved into quarantine. Persisted as strings in
 * [za.co.voelgoed.fastcheck.data.local.QuarantinedScanEntity].
 */
enum class QuarantineReason(val wireValue: String) {
    UNRECOVERABLE_API_CONTRACT_ERROR("UNRECOVERABLE_API_CONTRACT_ERROR"),
    INCOMPLETE_SERVER_RESPONSE("INCOMPLETE_SERVER_RESPONSE"),
    UNSUPPORTED_SERVER_RESPONSE_SHAPE("UNSUPPORTED_SERVER_RESPONSE_SHAPE"),
    INVALID_PERSISTED_PAYLOAD("INVALID_PERSISTED_PAYLOAD"),
    BATCH_ATTRIBUTION_UNAVAILABLE("BATCH_ATTRIBUTION_UNAVAILABLE");

    companion object {
        fun fromWire(value: String): QuarantineReason? =
            entries.firstOrNull { it.wireValue == value }
    }
}
