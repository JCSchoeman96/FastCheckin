package za.co.voelgoed.fastcheck.data.mapper

import java.time.Clock
import za.co.voelgoed.fastcheck.data.local.SyncMetadataEntity
import za.co.voelgoed.fastcheck.domain.model.AttendeeSyncStatus

fun SyncMetadataEntity.toDomain(): AttendeeSyncStatus =
    AttendeeSyncStatus(
        eventId = eventId,
        lastServerTime = lastServerTime,
        lastSuccessfulSyncAt = lastSuccessfulSyncAt,
        syncType = lastSyncType,
        attendeeCount = attendeeCount,
        bootstrapCompletedAt = bootstrapCompletedAt ?: lastSuccessfulSyncAt,
        lastAttemptedSyncAt = lastAttemptedSyncAt,
        consecutiveFailures = consecutiveFailures,
        lastErrorCode = lastErrorCode,
        lastErrorAt = lastErrorAt,
        lastFullReconcileAt = lastFullReconcileAt,
        incrementalCyclesSinceFullReconcile = incrementalCyclesSinceFullReconcile,
        consecutiveIntegrityFailures = consecutiveIntegrityFailures
    )

fun SyncMetadataEntity.withSyncFailure(
    clock: Clock,
    errorCode: String
): SyncMetadataEntity {
    val nowIso = clock.instant().toString()
    return copy(
        lastAttemptedSyncAt = nowIso,
        consecutiveFailures = consecutiveFailures + 1,
        lastErrorCode = errorCode,
        lastErrorAt = nowIso
    )
}

fun SyncMetadataEntity.withIntegrityFailure(clock: Clock): SyncMetadataEntity {
    val nowIso = clock.instant().toString()
    return copy(
        lastAttemptedSyncAt = nowIso,
        consecutiveIntegrityFailures = consecutiveIntegrityFailures + 1,
        integrityFailuresInForegroundSession = integrityFailuresInForegroundSession + 1,
        lastErrorCode = "integrity",
        lastErrorAt = nowIso
    )
}
