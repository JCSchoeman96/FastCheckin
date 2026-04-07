package za.co.voelgoed.fastcheck.data.repository

import javax.inject.Inject
import javax.inject.Singleton
import za.co.voelgoed.fastcheck.data.local.ScannerDao

/**
 * Default cleaner that applies retention policies to non-secret runtime tables.
 */
@Singleton
class DefaultLocalRuntimeDataCleaner @Inject constructor(
    private val scannerDao: ScannerDao
) : LocalRuntimeDataCleaner {
    override suspend fun handleExplicitLogout(currentEventId: Long?) {
        apply(RuntimeDataRetentionPolicy.forTransition(LocalRuntimeTransition.EXPLICIT_LOGOUT))
    }

    override suspend fun handleAuthExpired(currentEventId: Long?) {
        apply(RuntimeDataRetentionPolicy.forTransition(LocalRuntimeTransition.AUTH_EXPIRED))
    }

    override suspend fun handleCleanEventTransition(fromEventId: Long?, toEventId: Long) {
        val policy = RuntimeDataRetentionPolicy.forTransition(LocalRuntimeTransition.CLEAN_EVENT_TRANSITION)
        if (fromEventId != null && fromEventId != toEventId) {
            if (policy.clearAttendees) scannerDao.deleteAttendeesForEvent(fromEventId)
            if (policy.clearSyncMetadata) scannerDao.deleteSyncMetadataForEvent(fromEventId)
        }
        if (policy.clearReplaySuppression) scannerDao.clearReplaySuppression()
        if (policy.clearReplayCache) scannerDao.clearReplayCache()
        if (policy.clearLatestFlushSnapshot) scannerDao.clearLatestFlushSnapshot()
        if (policy.clearRecentFlushOutcomes) scannerDao.clearRecentFlushOutcomes()
    }

    private suspend fun apply(policy: RuntimeDataRetentionPolicy) {
        if (policy.clearAttendees) scannerDao.deleteAllAttendees()
        if (policy.clearSyncMetadata) scannerDao.deleteAllSyncMetadata()
        if (policy.clearReplaySuppression) scannerDao.clearReplaySuppression()
        if (policy.clearReplayCache) scannerDao.clearReplayCache()
        if (policy.clearLatestFlushSnapshot) scannerDao.clearLatestFlushSnapshot()
        if (policy.clearRecentFlushOutcomes) scannerDao.clearRecentFlushOutcomes()
    }
}
