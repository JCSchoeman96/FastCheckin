package za.co.voelgoed.fastcheck.data.repository

import java.time.Clock
import javax.inject.Inject
import javax.inject.Singleton
import za.co.voelgoed.fastcheck.core.session.AuthenticatedSessionTransitionCoordinator
import za.co.voelgoed.fastcheck.data.mapper.toDomain
import za.co.voelgoed.fastcheck.data.remote.MobileLoginRequest
import za.co.voelgoed.fastcheck.data.remote.PhoenixMobileRemoteDataSource
import za.co.voelgoed.fastcheck.domain.model.ScannerSession

@Singleton
class CurrentPhoenixSessionRepository @Inject constructor(
    private val remoteDataSource: PhoenixMobileRemoteDataSource,
    private val transitionCoordinator: AuthenticatedSessionTransitionCoordinator,
    private val clock: Clock
) : SessionRepository {
    override suspend fun login(eventId: Long, credential: String): ScannerSession {
        val response = remoteDataSource.login(MobileLoginRequest(event_id = eventId, credential = credential))
        val payload = requireNotNull(response.data) { response.message ?: response.error ?: "Login failed" }
        return transitionCoordinator.commitLogin(payload.toDomain(clock), payload.token)
    }

    override suspend fun currentSession(): ScannerSession? = transitionCoordinator.restore()
    override suspend fun logout() { transitionCoordinator.logout() }
    override suspend fun onAuthExpired() { transitionCoordinator.expireCurrent() }
}
