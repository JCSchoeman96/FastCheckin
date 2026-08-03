package za.co.voelgoed.fastcheck.core.network

import java.io.IOException
import kotlinx.coroutines.runBlocking
import za.co.voelgoed.fastcheck.core.session.AuthenticatedEventContextStore
import okhttp3.Interceptor
import okhttp3.Response

class AuthHeaderInterceptor(
    private val contextStore: AuthenticatedEventContextStore
) : Interceptor {
    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        val requestBuilder = request.newBuilder()
        val path = request.url.encodedPath

        if (path.endsWith("/api/v1/mobile/login")) {
            requestBuilder.removeHeader("Authorization")
        } else if (path.endsWith("/api/v1/mobile/attendees") || path.endsWith("/api/v1/mobile/scans")) {
            if (request.header("Authorization").isNullOrBlank()) {
                throw IOException("Explicit captured authorization is required for mobile sync and upload")
            }
        } else if (request.header("Authorization").isNullOrBlank()) {
            val token = runBlocking { contextStore.capture()?.bearerToken }

            if (!token.isNullOrBlank()) {
                requestBuilder.header("Authorization", "Bearer $token")
            }
        }

        return chain.proceed(requestBuilder.build())
    }
}
