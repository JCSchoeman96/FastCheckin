package za.co.voelgoed.fastcheck.di

import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.coroutines.CompletableDeferred
import za.co.voelgoed.fastcheck.data.repository.SessionRepository
import za.co.voelgoed.fastcheck.domain.model.ScannerSession

@Singleton
class TestSessionRepository @Inject constructor() : SessionRepository {
    @Volatile
    private var currentSessionValue: ScannerSession? = null

    @Volatile
    var loginFailure: Throwable? = null

    @Volatile
    var nextSessionGeneration: Long? = null

    @Volatile
    var loginCallCount: Int = 0
        private set

    @Volatile
    private var logoutRelease: CompletableDeferred<Unit>? = null

    override suspend fun login(eventId: Long, credential: String): ScannerSession {
        loginCallCount += 1
        loginFailure?.let { throw it }
        return session(
            eventId = eventId,
            eventName = "Test Event",
            authenticatedAtEpochMillis = System.currentTimeMillis(),
            sessionGeneration = nextSessionGeneration
        ).also { session ->
            currentSessionValue = session
        }
    }

    override suspend fun currentSession(): ScannerSession? = currentSessionValue

    override suspend fun logout() {
        logoutRelease?.await()
        logoutRelease = null
        currentSessionValue = null
    }

    override suspend fun onAuthExpired() {
        currentSessionValue = null
    }

    fun setCurrentSession(session: ScannerSession?) {
        currentSessionValue = session
    }

    fun delayNextLogout() {
        logoutRelease = CompletableDeferred()
    }

    fun completeLogout() {
        checkNotNull(logoutRelease) { "No delayed logout is pending." }.complete(Unit)
    }

    fun reset() {
        currentSessionValue = null
        loginFailure = null
        nextSessionGeneration = null
        loginCallCount = 0
        logoutRelease?.complete(Unit)
        logoutRelease = null
    }

    fun session(
        eventId: Long,
        eventName: String = "Test Event",
        authenticatedAtEpochMillis: Long,
        sessionGeneration: Long? = null
    ): ScannerSession =
        ScannerSession(
            eventId = eventId,
            eventName = eventName,
            expiresInSeconds = 3600,
            authenticatedAtEpochMillis = authenticatedAtEpochMillis,
            expiresAtEpochMillis = authenticatedAtEpochMillis + 3_600_000,
            sessionGeneration = sessionGeneration
        )
}
