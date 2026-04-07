package za.co.voelgoed.fastcheck.data.repository

/**
 * Narrow value holder describing what local runtime surfaces should be retained
 * across a transition. Queue, overlays, and quarantine default to retained.
 */
data class RuntimeDataRetentionPolicy(
    val clearAttendees: Boolean,
    val clearSyncMetadata: Boolean,
    val clearReplaySuppression: Boolean,
    val clearReplayCache: Boolean,
    val clearLatestFlushSnapshot: Boolean,
    val clearRecentFlushOutcomes: Boolean,
    val preserveQueuedScans: Boolean = true,
    val preserveLocalAdmissionOverlays: Boolean = true,
    val preserveQuarantinedScans: Boolean = true
) {
    companion object {
        fun forTransition(transition: LocalRuntimeTransition): RuntimeDataRetentionPolicy =
            when (transition) {
                LocalRuntimeTransition.EXPLICIT_LOGOUT ->
                    RuntimeDataRetentionPolicy(
                        clearAttendees = true,
                        clearSyncMetadata = true,
                        clearReplaySuppression = true,
                        clearReplayCache = true,
                        clearLatestFlushSnapshot = true,
                        clearRecentFlushOutcomes = true
                    )

                LocalRuntimeTransition.AUTH_EXPIRED ->
                    RuntimeDataRetentionPolicy(
                        clearAttendees = false,
                        clearSyncMetadata = false,
                        clearReplaySuppression = true,
                        clearReplayCache = false,
                        clearLatestFlushSnapshot = false,
                        clearRecentFlushOutcomes = false
                    )

                LocalRuntimeTransition.SAME_EVENT_RELOGIN ->
                    RuntimeDataRetentionPolicy(
                        clearAttendees = false,
                        clearSyncMetadata = false,
                        clearReplaySuppression = false,
                        clearReplayCache = false,
                        clearLatestFlushSnapshot = false,
                        clearRecentFlushOutcomes = false
                    )

                LocalRuntimeTransition.CLEAN_EVENT_TRANSITION ->
                    RuntimeDataRetentionPolicy(
                        clearAttendees = true,
                        clearSyncMetadata = true,
                        clearReplaySuppression = true,
                        clearReplayCache = true,
                        clearLatestFlushSnapshot = true,
                        clearRecentFlushOutcomes = true
                    )

                LocalRuntimeTransition.RESTORED_SESSION_BLOCKED_UNRESOLVED_STATE ->
                    RuntimeDataRetentionPolicy(
                        clearAttendees = false,
                        clearSyncMetadata = false,
                        clearReplaySuppression = false,
                        clearReplayCache = false,
                        clearLatestFlushSnapshot = false,
                        clearRecentFlushOutcomes = false
                    )
            }
    }
}
