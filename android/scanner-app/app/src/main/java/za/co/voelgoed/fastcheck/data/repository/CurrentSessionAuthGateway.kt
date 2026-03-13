package za.co.voelgoed.fastcheck.data.repository

import javax.inject.Inject
import javax.inject.Singleton

@Singleton
/**
 * Current implementation of [SessionAuthGateway] backed by the event-scoped
 * JWT session model and non-secret scanner preferences.
 */
class CurrentSessionAuthGateway @Inject constructor(
    private val sessionRepository: SessionRepository,
    private val scannerPreferencesStore: ScannerPreferencesStore
) : SessionAuthGateway {
    override suspend fun currentEventId(): Long? = sessionRepository.currentSession()?.eventId

    override suspend fun currentOperatorName(): String? = scannerPreferencesStore.loadOperatorName()
}
