package za.co.voelgoed.fastcheck.feature.scanning.screen

import java.time.Clock
import java.time.Duration
import java.time.Instant
import za.co.voelgoed.fastcheck.domain.model.AttendeeSyncStatus
import za.co.voelgoed.fastcheck.domain.policy.AdmissionRuntimePolicy
import za.co.voelgoed.fastcheck.feature.sync.BootstrapSyncStatus
import za.co.voelgoed.fastcheck.feature.sync.SyncScreenUiState

/** Evaluates scan-screen cache freshness and refresh action state from sync/session inputs. */
class AttendeeCacheFreshnessPolicy(
    private val clock: Clock
) {
    fun evaluate(
        syncUiState: SyncScreenUiState,
        currentEventSyncStatus: AttendeeSyncStatus?,
        isOnline: Boolean
    ): FreshnessDecision {
        if (syncUiState.isSyncing) {
            return FreshnessDecision(ScanRefreshState.Syncing, hasActionableRefresh = false)
        }
        if (syncUiState.isRateLimited) {
            return FreshnessDecision(
                state = ScanRefreshState.RateLimited,
                hasActionableRefresh = false
            )
        }

        val hasActiveEvent = currentEventSyncStatus != null || syncUiState.bootstrapEventId != null
        if (!hasActiveEvent) {
            return FreshnessDecision(ScanRefreshState.Fresh, hasActionableRefresh = false)
        }

        if (currentEventSyncStatus == null) {
            val state =
                if (syncUiState.bootstrapStatus == BootstrapSyncStatus.Failed || !syncUiState.errorMessage.isNullOrBlank()) {
                    ScanRefreshState.Failed
                } else {
                    ScanRefreshState.Missing
                }
            return FreshnessDecision(state = state, hasActionableRefresh = isOnline)
        }

        val lastSync = parseInstant(currentEventSyncStatus.lastSuccessfulSyncAt)
        if (lastSync == null) {
            return FreshnessDecision(ScanRefreshState.Missing, hasActionableRefresh = isOnline)
        }

        val age = Duration.between(lastSync, clock.instant())
        val isUnsafe = age >= AdmissionRuntimePolicy.ATTENDEE_CACHE_STALE_THRESHOLD
        val state =
            when {
                !isOnline && age >= STALE_THRESHOLD -> ScanRefreshState.OfflineStale
                syncUiState.bootstrapStatus == BootstrapSyncStatus.Failed || !syncUiState.errorMessage.isNullOrBlank() ->
                    ScanRefreshState.Failed
                age < FRESH_THRESHOLD -> ScanRefreshState.Fresh
                age < STALE_THRESHOLD -> ScanRefreshState.Aging
                else -> ScanRefreshState.Stale
            }

        val hasActionableRefresh =
            isOnline &&
                (state == ScanRefreshState.Stale ||
                    state == ScanRefreshState.Failed ||
                    state == ScanRefreshState.Missing ||
                    state == ScanRefreshState.OfflineStale)

        return FreshnessDecision(
            state = state,
            hasActionableRefresh = hasActionableRefresh,
            age = age,
            isUnsafe = isUnsafe
        )
    }

    private fun parseInstant(value: String?): Instant? =
        value?.let { runCatching { Instant.parse(it) }.getOrNull() }

    companion object {
        val FRESH_THRESHOLD: Duration = Duration.ofMinutes(5)
        val STALE_THRESHOLD: Duration = Duration.ofMinutes(15)
    }
}

enum class ScanRefreshState {
    Fresh,
    Aging,
    Stale,
    Missing,
    Syncing,
    Failed,
    OfflineStale,
    RateLimited
}

data class FreshnessDecision(
    val state: ScanRefreshState,
    val hasActionableRefresh: Boolean,
    val age: Duration? = null,
    val isUnsafe: Boolean = false
)

