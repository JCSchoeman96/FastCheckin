package za.co.voelgoed.fastcheck.core.network

import retrofit2.http.Body
import retrofit2.http.GET
import retrofit2.http.POST
import retrofit2.http.Query
import za.co.voelgoed.fastcheck.data.remote.MobileLoginRequest
import za.co.voelgoed.fastcheck.data.remote.MobileLoginResponse
import za.co.voelgoed.fastcheck.data.remote.MobileSyncResponse
import za.co.voelgoed.fastcheck.data.remote.UploadScansRequest
import za.co.voelgoed.fastcheck.data.remote.UploadScansResponse

interface PhoenixMobileApi {
    @POST("/api/v1/mobile/login")
    suspend fun login(@Body body: MobileLoginRequest): MobileLoginResponse

    @GET("/api/v1/mobile/attendees")
    suspend fun syncAttendees(
        @Query("since") since: String? = null,
        @Query("cursor") cursor: String? = null,
        @Query("limit") limit: Int
    ): MobileSyncResponse

    @POST("/api/v1/mobile/scans")
    suspend fun uploadScans(@Body body: UploadScansRequest): UploadScansResponse
}
