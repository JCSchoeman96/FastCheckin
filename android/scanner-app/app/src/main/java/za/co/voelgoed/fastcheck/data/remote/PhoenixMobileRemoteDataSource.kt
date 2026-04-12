package za.co.voelgoed.fastcheck.data.remote

import java.time.Clock
import java.time.Duration
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter
import retrofit2.Response
import za.co.voelgoed.fastcheck.core.network.PhoenixMobileApi

class PhoenixMobileRemoteDataSource(
    private val api: PhoenixMobileApi,
    private val clock: Clock = Clock.systemUTC()
) {
    suspend fun login(request: MobileLoginRequest): MobileLoginResponse = api.login(request)

    suspend fun syncAttendees(
        since: String?,
        cursor: String? = null,
        sinceInvalidationId: Long = 0L,
        limit: Int
    ): MobileSyncResponse =
        api.syncAttendees(
            since = since,
            cursor = cursor,
            sinceInvalidationId = sinceInvalidationId,
            limit = limit
        )

    suspend fun uploadScans(scans: List<QueuedScanPayload>): UploadScansTransportResponse {
        val response = api.uploadScans(UploadScansRequest(scans = scans))

        return UploadScansTransportResponse(
            statusCode = response.code(),
            retryAfterMillis = parseRetryAfterMillis(response),
            rateLimitLimit = response.headers()["x-ratelimit-limit"]?.trim()?.toIntOrNull(),
            rateLimitRemaining = response.headers()["x-ratelimit-remaining"]?.trim()?.toIntOrNull(),
            rateLimitResetEpochSeconds = response.headers()["x-ratelimit-reset"]?.trim()?.toLongOrNull(),
            body = response.body(),
            errorBody = response.readErrorBody()
        )
    }

    private fun parseRetryAfterMillis(response: Response<*>): Long? {
        val headerValue = response.headers()["Retry-After"]?.trim()
        if (headerValue.isNullOrBlank()) return null

        headerValue.toLongOrNull()?.let { seconds ->
            if (seconds <= 0) return null
            return Duration.ofSeconds(seconds).toMillis()
        }

        return try {
            val retryTime =
                ZonedDateTime.parse(headerValue, DateTimeFormatter.RFC_1123_DATE_TIME).toInstant()
            val diff = Duration.between(clock.instant(), retryTime).toMillis()
            if (diff <= 0) null else diff
        } catch (_: Exception) {
            null
        }
    }

    private fun Response<*>.readErrorBody(): String? =
        try {
            errorBody()?.string()?.trim()?.takeIf { it.isNotEmpty() }
        } catch (_: Exception) {
            null
        }
}
