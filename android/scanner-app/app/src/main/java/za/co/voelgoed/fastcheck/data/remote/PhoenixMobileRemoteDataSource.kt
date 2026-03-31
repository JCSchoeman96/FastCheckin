package za.co.voelgoed.fastcheck.data.remote

import za.co.voelgoed.fastcheck.core.network.PhoenixMobileApi

class PhoenixMobileRemoteDataSource(
    private val api: PhoenixMobileApi
) {
    suspend fun login(request: MobileLoginRequest): MobileLoginResponse = api.login(request)

    suspend fun syncAttendees(
        since: String?,
        cursor: String? = null,
        limit: Int
    ): MobileSyncResponse = api.syncAttendees(since = since, cursor = cursor, limit = limit)

    suspend fun uploadScans(scans: List<QueuedScanPayload>): UploadScansResponse =
        api.uploadScans(UploadScansRequest(scans = scans))
}
