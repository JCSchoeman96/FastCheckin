package za.co.voelgoed.fastcheck.data.repository

import java.time.Clock
import javax.inject.Inject
import javax.inject.Singleton
import za.co.voelgoed.fastcheck.core.datastore.SessionMetadataStore
import za.co.voelgoed.fastcheck.core.security.SessionVault
import za.co.voelgoed.fastcheck.data.mapper.toDomain
import za.co.voelgoed.fastcheck.data.mapper.toMetadata
import za.co.voelgoed.fastcheck.data.remote.MobileLoginRequest
import za.co.voelgoed.fastcheck.data.remote.PhoenixMobileRemoteDataSource
import za.co.voelgoed.fastcheck.domain.model.ScannerSession

@Singleton
class CurrentPhoenixSessionRepository @Inject constructor(
    private val remoteDataSource: PhoenixMobileRemoteDataSource,
    private val sessionVault: SessionVault,
    private val sessionMetadataStore: SessionMetadataStore,
    private val unresolvedAdmissionStateGate: UnresolvedAdmissionStateGate,
    private val clock: Clock
) : SessionRepository {
    override suspend fun login(eventId: Long, credential: String): ScannerSession {
        unresolvedAdmissionStateGate.requireNoConflictingEvents(eventId)
        val response = remoteDataSource.login(MobileLoginRequest(event_id = eventId, credential = credential))
        val payload = requireNotNull(response.data) { response.message ?: response.error ?: "Login failed" }
        val session = payload.toDomain(clock)

        sessionVault.storeToken(payload.token)
        sessionMetadataStore.save(session.toMetadata())

        return session
    }

    override suspend fun currentSession(): ScannerSession? =
        sessionMetadataStore.load()?.toDomain()

    override suspend fun logout() {
        sessionVault.clearToken()
        sessionMetadataStore.clear()
    }
}
