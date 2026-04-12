package za.co.voelgoed.fastcheck.domain.policy

import java.time.Clock
import java.time.Duration
import java.time.Instant
import javax.inject.Inject
import za.co.voelgoed.fastcheck.domain.model.AttendeeSyncStatus

class CurrentEventAdmissionReadiness @Inject constructor(
    private val clock: Clock
) {
    @Deprecated("Use evaluateReadiness for stale vs unsafe decisions.")
    fun hasTrustedCurrentEventCache(
        eventId: Long,
        syncStatus: AttendeeSyncStatus?
    ): Boolean = evaluateReadiness(eventId, syncStatus, bootstrapSyncInProgress = false).readiness !=
        AdmissionCacheReadiness.NOT_READY_UNSAFE

    fun evaluateReadiness(
        eventId: Long,
        syncStatus: AttendeeSyncStatus?,
        bootstrapSyncInProgress: Boolean
    ): AdmissionReadinessEvaluation {
        if (syncStatus == null) {
            return AdmissionReadinessEvaluation(
                AdmissionCacheReadiness.NOT_READY_UNSAFE,
                AdmissionReadinessReason.MissingSyncMetadata
            )
        }

        if (syncStatus.eventId != eventId) {
            return AdmissionReadinessEvaluation(
                AdmissionCacheReadiness.NOT_READY_UNSAFE,
                AdmissionReadinessReason.WrongEvent
            )
        }

        if (bootstrapSyncInProgress) {
            return AdmissionReadinessEvaluation(
                AdmissionCacheReadiness.NOT_READY_UNSAFE,
                AdmissionReadinessReason.InitialBootstrapSyncInProgress
            )
        }

        val bootstrapAt = syncStatus.bootstrapCompletedAt ?: syncStatus.lastSuccessfulSyncAt
        if (bootstrapAt.isNullOrBlank()) {
            return AdmissionReadinessEvaluation(
                AdmissionCacheReadiness.NOT_READY_UNSAFE,
                AdmissionReadinessReason.BootstrapNotCompleted
            )
        }

        runCatching { Instant.parse(bootstrapAt) }.getOrNull()
            ?: return AdmissionReadinessEvaluation(
                AdmissionCacheReadiness.NOT_READY_UNSAFE,
                AdmissionReadinessReason.CorruptOrInconsistentSyncState
            )

        val lastSuccessfulSyncAt = syncStatus.lastSuccessfulSyncAt
            ?: return AdmissionReadinessEvaluation(
                AdmissionCacheReadiness.NOT_READY_UNSAFE,
                AdmissionReadinessReason.NeverSuccessfullySynced
            )

        val syncedAt = runCatching { Instant.parse(lastSuccessfulSyncAt) }.getOrNull()
            ?: return AdmissionReadinessEvaluation(
                AdmissionCacheReadiness.NOT_READY_UNSAFE,
                AdmissionReadinessReason.UnparseableSyncTimestamp
            )

        val age = Duration.between(syncedAt, clock.instant())
        return if (age > AdmissionRuntimePolicy.ATTENDEE_CACHE_STALE_THRESHOLD) {
            AdmissionReadinessEvaluation(AdmissionCacheReadiness.READY_STALE, AdmissionReadinessReason.ReadyStale)
        } else {
            AdmissionReadinessEvaluation(AdmissionCacheReadiness.READY_FRESH, AdmissionReadinessReason.ReadyFresh)
        }
    }
}
