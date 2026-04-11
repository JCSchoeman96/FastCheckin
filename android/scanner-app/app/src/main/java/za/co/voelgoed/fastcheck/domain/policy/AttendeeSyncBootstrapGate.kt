package za.co.voelgoed.fastcheck.domain.policy

/**
 * Bridges attendee sync orchestration into admission readiness: first-time bootstrap must block
 * green admission until a coherent sync completes, while incremental sync runs must not.
 */
interface AttendeeSyncBootstrapGate {
    fun isInitialBootstrapSyncInProgressForEvent(eventId: Long): Boolean
}
