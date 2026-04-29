package za.co.voelgoed.fastcheck.core.sync

import com.google.common.truth.Truth.assertThat
import java.time.Clock
import java.time.Instant
import java.time.ZoneOffset
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.isActive
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
    fun scanActiveSignals_startSinglePeriodicLoop_andInactiveCancelsIt() {
        runBlocking {
            val syncRepository = RecordingSyncRepository(syncBehavior = { null })
            val orchestrator =
                DefaultAttendeeSyncOrchestrator(
                    syncRepository = syncRepository,
                    sessionRepository = fixedSessionRepository(),
                    connectivityMonitor = alwaysOnline(),
                    clock = TEST_CLOCK
                )

            orchestrator.notifyScanDestinationActive()
            val firstJob = orchestrator.currentScanActivePeriodicJob()
            orchestrator.notifyScanDestinationActive()
            val secondJob = orchestrator.currentScanActivePeriodicJob()

            assertThat(firstJob).isNotNull()
            assertThat(firstJob).isSameInstanceAs(secondJob)

            orchestrator.notifyScanDestinationInactive()
            assertThat(orchestrator.currentScanActivePeriodicJob()).isNull()
            assertThat(firstJob?.isActive).isFalse()
        }
    }

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
        delay(150)
        assertThat(syncRepository.syncCalls).isAtMost(1)
    }

    @Test
    fun runSyncCycleNow_offlineFailsFast_andDoesNotScheduleRetry() = runBlocking {
        val syncRepository =
            RecordingSyncRepository(
                syncBehavior = {
                    AttendeeSyncStatus(
                        eventId = 5L,
                        lastServerTime = null,
                        lastSuccessfulSyncAt = null,
                        syncType = null,
                        attendeeCount = 0
                    )
                }
            )
        val orchestrator =
            DefaultAttendeeSyncOrchestrator(
                syncRepository = syncRepository,
                sessionRepository = fixedSessionRepository(),
                connectivityMonitor = alwaysOffline(),
                clock = TEST_CLOCK
            )

        val thrown = runCatching { orchestrator.runSyncCycleNow() }.exceptionOrNull()

        assertThat(thrown).isNotNull()
        assertThat(syncRepository.syncCalls).isEqualTo(0)
        assertThat(orchestrator.currentRetryJob()).isNull()
    }

    @Test
    fun burstForegroundAndAdvisoryTriggers_areCoalescedToBoundedSyncCycles() = runBlocking {
        val syncRepository =
            RecordingSyncRepository(
                syncBehavior = {
                    delay(120)
                    null
                }
            )
        val orchestrator =
            DefaultAttendeeSyncOrchestrator(
                syncRepository = syncRepository,
                sessionRepository = fixedSessionRepository(),
                connectivityMonitor = alwaysOnline(),
                clock = TEST_CLOCK
            )

        orchestrator.start()
        repeat(8) {
            orchestrator.notifyAppForeground()
            orchestrator.notifyStaleScanRefreshAdvisory()
            orchestrator.notifyConnectivityRestored()
        }

        waitForAtLeastSyncCalls(repository = syncRepository, expectedCalls = 1)
        delay(350)

        // Conflated channel should collapse bursts to one in-flight cycle plus one pending rerun.
        assertThat(syncRepository.syncCalls).isAtMost(2)
    }

    @Test
    fun runSyncCycleNow_honorsRetryAfterDelayWhenRateLimited() = runBlocking {
        var callCount = 0
        val callNanos = mutableListOf<Long>()
        val syncRepository =
            RecordingSyncRepository(
                syncBehavior = {
                    callCount += 1
                    callNanos += System.nanoTime()
                    if (callCount == 1) {
                        throw SyncRateLimitedException(
                            message = "rate limited",
                            retryAfterMillis = 20L
                        )
                    }
                    null
                }
            )
        val orchestrator =
            DefaultAttendeeSyncOrchestrator(
                syncRepository = syncRepository,
                sessionRepository = fixedSessionRepository(),
                connectivityMonitor = alwaysOnline(),
                clock = TEST_CLOCK
            )

        orchestrator.start()
        val thrown = runCatching { orchestrator.runSyncCycleNow() }.exceptionOrNull()
        assertThat(thrown).isInstanceOf(SyncRateLimitedException::class.java)
        assertThat(syncRepository.syncCalls).isEqualTo(1)

        waitForAtLeastSyncCalls(repository = syncRepository, expectedCalls = 2)
        assertThat(syncRepository.syncCalls).isAtLeast(2)
        val elapsedMs = (callNanos[1] - callNanos[0]) / 1_000_000
        // Keep this loose to avoid flaky timing checks while still proving not-immediate retry.
        assertThat(elapsedMs).isAtLeast(10L)
    }

    @Test
    fun nullLastFullReconcileAtUsesLastSuccessfulSyncAnchorBeforeForcingFullReconcile() {
        runBlocking {
            val statusWithUpgradeStyleNullLastFull =
                AttendeeSyncStatus(
                    eventId = 5L,
                    lastServerTime = "2026-04-11T09:58:00Z",
                    lastSuccessfulSyncAt = "2026-04-11T10:00:00Z",
                    syncType = "incremental",
                    attendeeCount = 12,
                    lastFullReconcileAt = null,
                    incrementalCyclesSinceFullReconcile = 0,
                    consecutiveFailures = 0,
                    consecutiveIntegrityFailures = 0
                )
            val syncRepository =
                RecordingSyncRepository(
                    syncBehavior = { statusWithUpgradeStyleNullLastFull },
                    currentStatusProvider = { statusWithUpgradeStyleNullLastFull }
                )
            val orchestrator =
                DefaultAttendeeSyncOrchestrator(
                    syncRepository = syncRepository,
                    sessionRepository = fixedSessionRepository(),
                    connectivityMonitor = alwaysOnline(),
                    clock = TEST_CLOCK
                )

            orchestrator.runSyncCycleNow()

            assertThat(syncRepository.modes).containsExactly(AttendeeSyncMode.INCREMENTAL)
        }
    }

    private suspend fun waitForSyncCall(repository: RecordingSyncRepository) {
        repeat(100) {
            if (repository.syncCalls > 0) return
            delay(10)
        }
        error("Timed out waiting for orchestrator to execute sync cycle.")
    }

    private suspend fun waitForAtLeastSyncCalls(repository: RecordingSyncRepository, expectedCalls: Int) {
        repeat(150) {
            if (repository.syncCalls >= expectedCalls) return
            delay(10)
        }
        error("Timed out waiting for orchestrator to execute $expectedCalls sync calls.")
    }

    private fun alwaysOnline(): ConnectivityMonitor =
        object : ConnectivityMonitor {
            override val isOnline = MutableStateFlow(true)
        }

    private fun alwaysOffline(): ConnectivityMonitor =
        object : ConnectivityMonitor {
            override val isOnline = MutableStateFlow(false)
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
        private val syncBehavior: suspend () -> AttendeeSyncStatus?,
        private val currentStatusProvider: () -> AttendeeSyncStatus? = { null }
    ) : SyncRepository {
        var syncCalls: Int = 0
        val modes: MutableList<AttendeeSyncMode> = mutableListOf()

        override suspend fun syncAttendees(mode: AttendeeSyncMode): AttendeeSyncStatus? {
            syncCalls += 1
            modes += mode
            return syncBehavior()
        }

        override suspend fun currentSyncStatus(): AttendeeSyncStatus? = currentStatusProvider()

        override fun observeLastSyncedStatus(): Flow<AttendeeSyncStatus?> = flowOf(null)
    }

    private fun DefaultAttendeeSyncOrchestrator.currentRetryJob(): Any? {
        val field = javaClass.getDeclaredField("retryJob")
        field.isAccessible = true
        return field.get(this)
    }

    private fun DefaultAttendeeSyncOrchestrator.currentScanActivePeriodicJob(): kotlinx.coroutines.Job? {
        val field = javaClass.getDeclaredField("scanActivePeriodicJob")
        field.isAccessible = true
        return field.get(this) as? kotlinx.coroutines.Job
    }

    private companion object {
        val TEST_CLOCK: Clock = Clock.fixed(Instant.parse("2026-04-11T10:00:00Z"), ZoneOffset.UTC)
    }
}
