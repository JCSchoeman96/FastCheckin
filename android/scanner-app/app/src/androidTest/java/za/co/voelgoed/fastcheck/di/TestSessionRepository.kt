package za.co.voelgoed.fastcheck.di

import javax.inject.Inject
import javax.inject.Singleton
import za.co.voelgoed.fastcheck.data.repository.SessionRepository
import za.co.voelgoed.fastcheck.domain.model.ScannerSession

@Singleton
class TestSessionRepository @Inject constructor() : SessionRepository {
    @Volatile
    private var currentSessionValue: ScannerSession? = null

    override suspend fun login(eventId: Long, credential: String): ScannerSession =
        session(
            eventId = eventId,
            eventName = "Test Event",
            authenticatedAtEpochMillis = System.currentTimeMillis()
        ).also { session ->
            currentSessionValue = session
        }

    override suspend fun currentSession(): ScannerSession? = currentSessionValue

    override suspend fun logout() {
        currentSessionValue = null
    }

    override suspend fun onAuthExpired() {
        currentSessionValue = null
    }

    override suspend fun clearBlockedRestoredSession() {
        currentSessionValue = null
    }

    fun setCurrentSession(session: ScannerSession?) {
        currentSessionValue = session
    }

    fun session(
        eventId: Long,
        eventName: String = "Test Event",
        authenticatedAtEpochMillis: Long
    ): ScannerSession =
        ScannerSession(
            eventId = eventId,
            eventName = eventName,
            expiresInSeconds = 3600,
            authenticatedAtEpochMillis = authenticatedAtEpochMillis,
            expiresAtEpochMillis = authenticatedAtEpochMillis + 3_600_000
        )
}
