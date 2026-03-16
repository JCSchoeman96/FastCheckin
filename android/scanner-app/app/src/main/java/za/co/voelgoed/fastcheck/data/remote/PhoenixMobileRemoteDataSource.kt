package za.co.voelgoed.fastcheck.data.remote

import za.co.voelgoed.fastcheck.core.network.PhoenixMobileApi

class PhoenixMobileRemoteDataSource(
    private val api: PhoenixMobileApi
) {
    suspend fun login(request: MobileLoginRequest): MobileLoginResponse = api.login(request)

    suspend fun syncAttendees(since: String?): MobileSyncResponse = api.syncAttendees(since)

    suspend fun uploadScans(scans: List<QueuedScanPayload>): UploadScansResponse =
        api.uploadScans(UploadScansRequest(scans = scans))
}
