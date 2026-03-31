package za.co.voelgoed.fastcheck.data.repository

import com.google.common.truth.Truth.assertThat
import java.time.Clock
import java.time.Instant
import java.time.ZoneOffset
import kotlinx.coroutines.test.runTest
import org.junit.Test
import za.co.voelgoed.fastcheck.core.datastore.SessionMetadata
import za.co.voelgoed.fastcheck.core.datastore.SessionMetadataStore
import za.co.voelgoed.fastcheck.core.network.PhoenixMobileApi
import za.co.voelgoed.fastcheck.core.security.SessionVault
import za.co.voelgoed.fastcheck.data.remote.MobileLoginPayload
import za.co.voelgoed.fastcheck.data.remote.MobileLoginRequest
import za.co.voelgoed.fastcheck.data.remote.MobileLoginResponse
import za.co.voelgoed.fastcheck.data.remote.MobileSyncResponse
import za.co.voelgoed.fastcheck.data.remote.PhoenixMobileRemoteDataSource
import za.co.voelgoed.fastcheck.data.remote.UploadScansResponse
import za.co.voelgoed.fastcheck.data.remote.UploadScansRequest

class CurrentPhoenixSessionRepositoryTest {
    private val clock = Clock.fixed(Instant.parse("2026-03-13T08:00:00Z"), ZoneOffset.UTC)

    @Test
    fun persistsJwtSeparatelyFromSessionMetadata() = runTest {
        val vault = FakeSessionVault()
        val metadataStore = FakeSessionMetadataStore()
        val repository =
            CurrentPhoenixSessionRepository(
                remoteDataSource =
                    PhoenixMobileRemoteDataSource(
                        FakePhoenixMobileApi(
                            MobileLoginResponse(
                                data =
                                    MobileLoginPayload(
                                        token = "jwt-token",
                                        event_id = 77,
                                        event_name = "FastCheck Event",
                                        expires_in = 7200
                                    ),
                                error = null,
                                message = null
                            )
                        )
                    ),
                sessionVault = vault,
                sessionMetadataStore = metadataStore,
                clock = clock
            )

        val session = repository.login(eventId = 77, credential = "scanner-secret")

        assertThat(vault.token).isEqualTo("jwt-token")
        assertThat(metadataStore.saved?.eventId).isEqualTo(77)
        assertThat(metadataStore.saved?.eventName).isEqualTo("FastCheck Event")
        assertThat(session.expiresAtEpochMillis).isEqualTo(1_773_396_000_000)
    }

    @Test
    fun restoresCurrentSessionFromStoredMetadata() = runTest {
        val metadataStore =
            FakeSessionMetadataStore().apply {
                saved =
                    SessionMetadata(
                        eventId = 5,
                        eventName = "Stored Event",
                        expiresInSeconds = 3600,
                        authenticatedAtEpochMillis = 1_773_388_800_000,
                        expiresAtEpochMillis = 1_773_392_400_000
                    )
            }

        val repository =
            CurrentPhoenixSessionRepository(
                remoteDataSource =
                    PhoenixMobileRemoteDataSource(
                        FakePhoenixMobileApi(
                            MobileLoginResponse(data = null, error = "unused", message = "unused")
                        )
                    ),
                sessionVault = FakeSessionVault(),
                sessionMetadataStore = metadataStore,
                clock = clock
            )

        val session = repository.currentSession()

        assertThat(session?.eventId).isEqualTo(5)
        assertThat(session?.eventName).isEqualTo("Stored Event")
        assertThat(session?.authenticatedAtEpochMillis).isEqualTo(1_773_388_800_000)
    }

    private class FakeSessionVault : SessionVault {
        var token: String? = null

        override suspend fun storeToken(token: String) {
            this.token = token
        }

        override suspend fun loadToken(): String? = token

        override suspend fun clearToken() {
            token = null
        }
    }

    private class FakeSessionMetadataStore : SessionMetadataStore {
        var saved: SessionMetadata? = null

        override suspend fun load(): SessionMetadata? = saved

        override suspend fun save(metadata: SessionMetadata) {
            saved = metadata
        }

        override suspend fun clear() {
            saved = null
        }
    }

    private class FakePhoenixMobileApi(
        private val loginResponse: MobileLoginResponse
    ) : PhoenixMobileApi {
        override suspend fun login(body: MobileLoginRequest): MobileLoginResponse = loginResponse

        override suspend fun syncAttendees(since: String?, cursor: String?, limit: Int): MobileSyncResponse {
            error("Not used in this test")
        }

        override suspend fun uploadScans(body: UploadScansRequest): UploadScansResponse {
            error("Not used in this test")
        }
    }
}
