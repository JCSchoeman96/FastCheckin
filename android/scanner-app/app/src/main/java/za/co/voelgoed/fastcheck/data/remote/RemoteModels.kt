package za.co.voelgoed.fastcheck.data.remote

data class MobileLoginRequest(
    val event_id: Long,
    val credential: String
)

data class MobileLoginResponse(
    val data: MobileLoginPayload?,
    val error: String?,
    val message: String?
)

data class MobileLoginPayload(
    val token: String,
    val event_id: Long,
    val event_name: String,
    val expires_in: Int
)

data class MobileSyncResponse(
    val data: MobileSyncPayload?,
    val error: String?,
    val message: String?
)

data class MobileSyncPayload(
    val server_time: String,
    val attendees: List<AttendeeDto>,
    val count: Int,
    val sync_type: String
)

data class AttendeeDto(
    val id: Long,
    val event_id: Long,
    val ticket_code: String,
    val first_name: String?,
    val last_name: String?,
    val email: String?,
    val ticket_type: String?,
    val allowed_checkins: Int,
    val checkins_remaining: Int,
    val payment_status: String?,
    val is_currently_inside: Boolean,
    val checked_in_at: String?,
    val checked_out_at: String?,
    val updated_at: String?
)

data class UploadScansRequest(
    val scans: List<QueuedScanPayload>
)

data class QueuedScanPayload(
    val idempotency_key: String,
    val ticket_code: String,
    val direction: String = "in",
    val scanned_at: String,
    val entrance_name: String,
    val operator_name: String
)

data class UploadScansResponse(
    val data: UploadScansPayload?,
    val error: String?,
    val message: String?
)

data class UploadScansPayload(
    val results: List<UploadedScanResult>,
    val processed: Int
)

data class UploadedScanResult(
    val idempotency_key: String,
    val status: String,
    val message: String,
    val reason_code: String? = null
)
