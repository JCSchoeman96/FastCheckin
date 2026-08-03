package za.co.voelgoed.fastcheck.core.network

import com.google.common.truth.Truth.assertThat
import java.io.IOException
import kotlinx.coroutines.flow.Flow
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Request
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Test
import za.co.voelgoed.fastcheck.core.session.AuthenticatedEventContext
import za.co.voelgoed.fastcheck.core.session.AuthenticatedEventContextStore
import za.co.voelgoed.fastcheck.core.session.AuthenticatedEventIdentity

class AuthHeaderInterceptorTest {
    @Test fun loginRemovesAuthorization() {
        val seen = execute("/api/v1/mobile/login", "Bearer accidental")
        assertThat(seen.header("Authorization")).isNull()
    }

    @Test fun attendeesWithoutExplicitHeaderFailsBeforeDispatch() {
        val dispatched = mutableListOf<Request>()
        val failure = runCatching { execute("/api/v1/mobile/attendees", dispatched = dispatched) }.exceptionOrNull()
        assertThat(failure).isInstanceOf(IOException::class.java)
        assertThat(dispatched).isEmpty()
    }

    @Test fun scansWithoutExplicitHeaderFailsBeforeDispatch() {
        val failure = runCatching { execute("/api/v1/mobile/scans") }.exceptionOrNull()
        assertThat(failure).isInstanceOf(IOException::class.java)
    }

    @Test fun explicitCapturedHeaderIsPreservedExactlyOnce() {
        val seen = execute("/api/v1/mobile/scans", "Bearer captured-a")
        assertThat(seen.headers("Authorization")).containsExactly("Bearer captured-a")
    }

    private fun execute(path: String, authorization: String? = null, dispatched: MutableList<Request> = mutableListOf()): Request {
        var seen: Request? = null
        val client = OkHttpClient.Builder()
            .addInterceptor(AuthHeaderInterceptor(FakeStore()))
            .addInterceptor { chain ->
                seen = chain.request(); dispatched += chain.request()
                Response.Builder().request(chain.request()).protocol(Protocol.HTTP_1_1).code(200)
                    .message("OK").body("{}".toResponseBody()).build()
            }.build()
        val builder = Request.Builder().url("https://example.test$path")
        authorization?.let { builder.header("Authorization", it) }
        client.newCall(builder.build()).execute().close()
        return requireNotNull(seen)
    }

    private class FakeStore : AuthenticatedEventContextStore {
        private val value = AuthenticatedEventContext(9, "current-token", 2, 0, Long.MAX_VALUE)
        override suspend fun capture() = value
        override suspend fun currentIdentity() = value.identity
        override suspend fun replace(eventId: Long, bearerToken: String, authenticatedAtEpochMillis: Long, expiresAtEpochMillis: Long) = error("unused")
        override suspend fun clearIfGenerationMatches(sessionGeneration: Long) = false
        override suspend fun isCurrent(sessionGeneration: Long) = sessionGeneration == 2L
        override fun observeIdentity(): Flow<AuthenticatedEventIdentity?> = kotlinx.coroutines.flow.flowOf(value.identity)
    }
}
