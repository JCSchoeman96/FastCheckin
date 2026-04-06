package za.co.voelgoed.fastcheck.domain.policy

import java.time.Clock
import java.time.Duration
import java.time.Instant
import javax.inject.Inject
import za.co.voelgoed.fastcheck.domain.model.AttendeeSyncStatus

class CurrentEventAdmissionReadiness @Inject constructor(
    private val clock: Clock
) {
    fun hasTrustedCurrentEventCache(
        eventId: Long,
        syncStatus: AttendeeSyncStatus?
    ): Boolean = evaluate(eventId, syncStatus).isTrusted

    fun evaluate(
        eventId: Long,
        syncStatus: AttendeeSyncStatus?
    ): AdmissionReadinessResult {
        if (syncStatus == null) {
            return AdmissionReadinessResult(false, AdmissionReadinessReason.MissingSyncMetadata)
        }

        if (syncStatus.eventId != eventId) {
            return AdmissionReadinessResult(false, AdmissionReadinessReason.WrongEvent)
        }

        val lastSuccessfulSyncAt = syncStatus.lastSuccessfulSyncAt
            ?: return AdmissionReadinessResult(false, AdmissionReadinessReason.NeverSuccessfullySynced)

        val syncedAt = runCatching { Instant.parse(lastSuccessfulSyncAt) }.getOrNull()
            ?: return AdmissionReadinessResult(false, AdmissionReadinessReason.UnparseableSyncTimestamp)

        val age = Duration.between(syncedAt, clock.instant())
        return if (age > AdmissionRuntimePolicy.ATTENDEE_CACHE_STALE_THRESHOLD) {
            AdmissionReadinessResult(false, AdmissionReadinessReason.Stale)
        } else {
            AdmissionReadinessResult(true, AdmissionReadinessReason.Ready)
        }
    }
}

data class AdmissionReadinessResult(
    val isTrusted: Boolean,
    val reason: AdmissionReadinessReason
)

enum class AdmissionReadinessReason {
    Ready,
    MissingSyncMetadata,
    WrongEvent,
    NeverSuccessfullySynced,
    UnparseableSyncTimestamp,
    Stale
}
