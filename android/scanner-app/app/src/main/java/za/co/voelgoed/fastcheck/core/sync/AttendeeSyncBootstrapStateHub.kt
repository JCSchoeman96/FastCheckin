package za.co.voelgoed.fastcheck.core.sync

import javax.inject.Inject
import javax.inject.Singleton
import za.co.voelgoed.fastcheck.domain.policy.AttendeeSyncBootstrapGate

/**
 * Process-local gate for first coherent attendee sync per event. The Phoenix sync repository
 * drives transitions; admission readiness reads without depending on orchestration details.
 */
@Singleton
class AttendeeSyncBootstrapStateHub @Inject constructor() : AttendeeSyncBootstrapGate {
    @Volatile
    private var initialBootstrapSyncEventId: Long? = null

    fun notifyInitialBootstrapSyncActive(eventId: Long?) {
        initialBootstrapSyncEventId = eventId
    }

    override fun isInitialBootstrapSyncInProgressForEvent(eventId: Long): Boolean =
        initialBootstrapSyncEventId == eventId
}
