package za.co.voelgoed.fastcheck.data.repository

import javax.inject.Inject
import javax.inject.Singleton
import za.co.voelgoed.fastcheck.core.session.AuthenticatedEventContextStore

@Singleton
/**
 * Current implementation of [SessionAuthGateway] backed by the event-scoped
 * JWT session model and non-secret scanner preferences.
 */
class CurrentSessionAuthGateway @Inject constructor(
    private val contextStore: AuthenticatedEventContextStore,
    private val scannerPreferencesStore: ScannerPreferencesStore
) : SessionAuthGateway {
    override suspend fun currentEventId(): Long? = contextStore.currentIdentity()?.eventId

    override suspend fun currentOperatorName(): String? = scannerPreferencesStore.loadOperatorName()
}
