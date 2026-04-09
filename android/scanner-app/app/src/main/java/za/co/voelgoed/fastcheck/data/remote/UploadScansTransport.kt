package za.co.voelgoed.fastcheck.data.remote

data class UploadScansTransportResponse(
    val statusCode: Int,
    val retryAfterMillis: Long?,
    val rateLimitLimit: Int?,
    val rateLimitRemaining: Int?,
    val rateLimitResetEpochSeconds: Long?,
    val body: UploadScansResponse?,
    val errorBody: String?
)
