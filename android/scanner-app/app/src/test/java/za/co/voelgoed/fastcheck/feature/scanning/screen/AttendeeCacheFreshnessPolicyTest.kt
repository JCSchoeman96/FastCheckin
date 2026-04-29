package za.co.voelgoed.fastcheck.feature.scanning.screen

import com.google.common.truth.Truth.assertThat
import java.time.Clock
import java.time.Instant
import java.time.ZoneOffset
import org.junit.Test
import za.co.voelgoed.fastcheck.domain.model.AttendeeSyncStatus
import za.co.voelgoed.fastcheck.feature.sync.BootstrapSyncStatus
import za.co.voelgoed.fastcheck.feature.sync.SyncScreenUiState

class AttendeeCacheFreshnessPolicyTest {
    private val clock = Clock.fixed(Instant.parse("2026-03-13T09:00:00Z"), ZoneOffset.UTC)
    private val policy = AttendeeCacheFreshnessPolicy(clock)

    @Test
    fun freshCacheIsUnderFiveMinutes() {
        val result = policy.evaluate(SyncScreenUiState(), statusAt("2026-03-13T08:56:00Z"), isOnline = true)
        assertThat(result.state).isEqualTo(ScanRefreshState.Fresh)
    }

    @Test
    fun agingCacheIsAtLeastFiveAndBelowFifteenMinutes() {
        val atFive = policy.evaluate(SyncScreenUiState(), statusAt("2026-03-13T08:55:00Z"), isOnline = true)
        val underFifteen = policy.evaluate(SyncScreenUiState(), statusAt("2026-03-13T08:45:01Z"), isOnline = true)
        assertThat(atFive.state).isEqualTo(ScanRefreshState.Aging)
        assertThat(underFifteen.state).isEqualTo(ScanRefreshState.Aging)
    }

    @Test
    fun staleCacheStartsAtFifteenMinutes() {
        val result = policy.evaluate(SyncScreenUiState(), statusAt("2026-03-13T08:45:00Z"), isOnline = true)
        assertThat(result.state).isEqualTo(ScanRefreshState.Stale)
        assertThat(result.hasActionableRefresh).isTrue()
    }

    @Test
    fun offlineStaleSuppressesActionableRefresh() {
        val result = policy.evaluate(SyncScreenUiState(), statusAt("2026-03-13T08:40:00Z"), isOnline = false)
        assertThat(result.state).isEqualTo(ScanRefreshState.OfflineStale)
        assertThat(result.hasActionableRefresh).isFalse()
    }

    @Test
    fun missingStatusUsesFailedStateWhenBootstrapFailed() {
        val result =
            policy.evaluate(
                SyncScreenUiState(bootstrapStatus = BootstrapSyncStatus.Failed, bootstrapEventId = 5L),
                currentEventSyncStatus = null,
                isOnline = true
            )
        assertThat(result.state).isEqualTo(ScanRefreshState.Failed)
        assertThat(result.hasActionableRefresh).isTrue()
    }

    @Test
    fun rateLimitedStateWins() {
        val result =
            policy.evaluate(
                SyncScreenUiState(isRateLimited = true, bootstrapEventId = 5L),
                statusAt("2026-03-13T08:40:00Z"),
                isOnline = true
            )
        assertThat(result.state).isEqualTo(ScanRefreshState.RateLimited)
        assertThat(result.hasActionableRefresh).isFalse()
    }

    private fun statusAt(lastSuccessfulSyncAt: String): AttendeeSyncStatus =
        AttendeeSyncStatus(
            eventId = 5,
            lastServerTime = lastSuccessfulSyncAt,
            lastSuccessfulSyncAt = lastSuccessfulSyncAt,
            syncType = "incremental",
            attendeeCount = 12
        )
}

