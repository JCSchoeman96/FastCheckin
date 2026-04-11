package za.co.voelgoed.fastcheck.core.sync

import com.google.common.truth.Truth.assertThat
import java.time.Clock
import java.time.Instant
import java.time.ZoneOffset
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.runBlocking
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import za.co.voelgoed.fastcheck.core.connectivity.ConnectivityMonitor
import za.co.voelgoed.fastcheck.data.repository.AttendeeSyncMode
import za.co.voelgoed.fastcheck.data.repository.SessionRepository
import za.co.voelgoed.fastcheck.data.repository.SyncRateLimitedException
import za.co.voelgoed.fastcheck.data.repository.SyncRepository
import za.co.voelgoed.fastcheck.domain.model.AttendeeSyncStatus
import za.co.voelgoed.fastcheck.domain.model.ScannerSession

/**
 * Verifies caller-observable versus background attendee sync failure behavior for the scanner app.
 */
@RunWith(RobolectricTestRunner::class)
class DefaultAttendeeSyncOrchestratorTest {
    @Test
    fun runSyncCycleNow_rethrowsTypedRateLimitError_andSchedulesRetry() = runBlocking {
        val syncRepository =
            RecordingSyncRepository(
                syncBehavior = {
                    throw SyncRateLimitedException(
                        message = "Sync is temporarily rate-limited.",
                        retryAfterMillis = 3_000L
                    )
                }
            )
        val orchestrator =
            DefaultAttendeeSyncOrchestrator(
                syncRepository = syncRepository,
                sessionRepository = fixedSessionRepository(),
                connectivityMonitor = alwaysOnline(),
                clock = TEST_CLOCK
            )

        val thrown =
            runCatching { orchestrator.runSyncCycleNow() }
                .exceptionOrNull()

        assertThat(thrown).isInstanceOf(SyncRateLimitedException::class.java)
        assertThat(syncRepository.syncCalls).isEqualTo(1)
        assertThat(orchestrator.currentRetryJob()).isNotNull()
    }

    @Test
    fun backgroundRequest_swallowsFailure_andSchedulesRetry() = runBlocking {
        val syncRepository =
            RecordingSyncRepository(
                syncBehavior = { throw IllegalStateException("network down") }
            )
        val orchestrator =
            DefaultAttendeeSyncOrchestrator(
                syncRepository = syncRepository,
                sessionRepository = fixedSessionRepository(),
                connectivityMonitor = alwaysOnline(),
                clock = TEST_CLOCK
            )

        orchestrator.start()
        orchestrator.notifyAppForeground()

        waitForSyncCall(syncRepository)

        assertThat(syncRepository.syncCalls).isGreaterThan(0)
        assertThat(orchestrator.currentRetryJob()).isNotNull()
    }

    private suspend fun waitForSyncCall(repository: RecordingSyncRepository) {
        repeat(100) {
            if (repository.syncCalls > 0) return
            delay(10)
        }
        error("Timed out waiting for orchestrator to execute sync cycle.")
    }

    private fun alwaysOnline(): ConnectivityMonitor =
        object : ConnectivityMonitor {
            override val isOnline = MutableStateFlow(true)
        }

    private fun fixedSessionRepository(): SessionRepository =
        object : SessionRepository {
            override suspend fun login(eventId: Long, credential: String): ScannerSession = sampleSession()

            override suspend fun currentSession(): ScannerSession = sampleSession()

            override suspend fun logout() = Unit

            override suspend fun onAuthExpired() = Unit

            override suspend fun clearBlockedRestoredSession() = Unit
        }

    private fun sampleSession(): ScannerSession =
        ScannerSession(
            eventId = 5L,
            eventName = "Voelgoed Live",
            expiresInSeconds = 3600,
            authenticatedAtEpochMillis = 1_773_388_800_000,
            expiresAtEpochMillis = 1_773_392_400_000
        )

    private class RecordingSyncRepository(
        private val syncBehavior: suspend () -> AttendeeSyncStatus?
    ) : SyncRepository {
        var syncCalls: Int = 0

        override suspend fun syncAttendees(mode: AttendeeSyncMode): AttendeeSyncStatus? {
            syncCalls += 1
            return syncBehavior()
        }

        override suspend fun currentSyncStatus(): AttendeeSyncStatus? = null

        override fun observeLastSyncedStatus(): Flow<AttendeeSyncStatus?> = flowOf(null)
    }

    private fun DefaultAttendeeSyncOrchestrator.currentRetryJob(): Any? {
        val field = javaClass.getDeclaredField("retryJob")
        field.isAccessible = true
        return field.get(this)
    }

    private companion object {
        val TEST_CLOCK: Clock = Clock.fixed(Instant.parse("2026-04-11T10:00:00Z"), ZoneOffset.UTC)
    }
}
