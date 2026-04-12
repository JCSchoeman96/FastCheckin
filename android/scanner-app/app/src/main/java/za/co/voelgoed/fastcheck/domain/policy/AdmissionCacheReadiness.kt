package za.co.voelgoed.fastcheck.domain.policy

/**
 * Local attendee-cache readiness for admission decisions (FastCheckin scanner domain).
 *
 * Distinguishes fresh cache, stale-but-usable cache, and unsafe states that require manual review.
 */
enum class AdmissionCacheReadiness {
    READY_FRESH,
    READY_STALE,
    NOT_READY_UNSAFE
}

enum class AdmissionReadinessReason {
    ReadyFresh,
    ReadyStale,
    MissingSyncMetadata,
    WrongEvent,
    NeverSuccessfullySynced,
    UnparseableSyncTimestamp,
    BootstrapNotCompleted,
    InitialBootstrapSyncInProgress,
    CorruptOrInconsistentSyncState
}

data class AdmissionReadinessEvaluation(
    val readiness: AdmissionCacheReadiness,
    val reason: AdmissionReadinessReason
)
