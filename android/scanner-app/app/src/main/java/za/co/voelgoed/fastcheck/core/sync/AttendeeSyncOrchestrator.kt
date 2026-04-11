package za.co.voelgoed.fastcheck.core.sync

/**
 * Owns attendee sync scheduling policy (periodic, reconnect, foreground, manual, stale-scan advisory).
 *
 * ViewModels and activities publish signals; this coordinator enforces single-flight execution and
 * trigger coalescing for the active event session.
 */
interface AttendeeSyncOrchestrator {
    fun start()

    fun notifyAppForeground()

    fun notifyStaleScanRefreshAdvisory()

    fun notifyConnectivityRestored()

    /**
     * Runs one sync cycle now (same mode resolution as background triggers). Use for operator
     * manual sync and bootstrap flows that must await completion.
     */
    suspend fun runSyncCycleNow()
}
