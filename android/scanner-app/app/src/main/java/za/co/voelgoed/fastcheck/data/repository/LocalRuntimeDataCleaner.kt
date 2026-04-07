package za.co.voelgoed.fastcheck.data.repository

/**
 * Applies local runtime retention policy for session and event transitions.
 * Queue, overlays, and quarantine are preserved by default.
 */
interface LocalRuntimeDataCleaner {
    suspend fun handleExplicitLogout(currentEventId: Long?)

    suspend fun handleAuthExpired(currentEventId: Long?)

    suspend fun handleCleanEventTransition(fromEventId: Long?, toEventId: Long)
}
