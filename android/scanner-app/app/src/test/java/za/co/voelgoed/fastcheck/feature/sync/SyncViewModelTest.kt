package za.co.voelgoed.fastcheck.feature.sync

import com.google.common.truth.Truth.assertThat
import java.time.Clock
import java.time.Instant
import java.time.ZoneOffset
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Before
import org.junit.Test
import za.co.voelgoed.fastcheck.data.repository.SyncRateLimitedException
import za.co.voelgoed.fastcheck.data.repository.SyncRepository
import za.co.voelgoed.fastcheck.domain.model.AttendeeSyncStatus

@OptIn(ExperimentalCoroutinesApi::class)
class SyncViewModelTest {
    private val dispatcher = StandardTestDispatcher()
    private val clock: Clock = Clock.fixed(Instant.parse("2026-03-13T08:30:00Z"), ZoneOffset.UTC)

    @Before
    fun setUp() {
        Dispatchers.setMain(dispatcher)
    }

    @After
    fun tearDown() {
        Dispatchers.resetMain()
    }

    private class RecordingSyncRepository(
        private val behavior: suspend () -> AttendeeSyncStatus?
    ) : SyncRepository {
        var callCount: Int = 0

        override suspend fun syncAttendees(): AttendeeSyncStatus? {
            callCount += 1
            return behavior()
        }

        override suspend fun currentSyncStatus(): AttendeeSyncStatus? {
            error("Not used in this test")
        }

        override fun observeLastSyncedStatus() =
            error("Not used in this test")
    }

    @Test
    fun rapidTapsWhileSyncing_doNotTriggerMultipleCalls() =
        runTest(dispatcher) {
            val repo =
                RecordingSyncRepository {
                    // Simulate some work so isSyncing stays true while we inspect.
                    AttendeeSyncStatus(
                        eventId = 5,
                        lastServerTime = "2026-03-13T08:20:00Z",
                        lastSuccessfulSyncAt = "2026-03-13T08:20:00Z",
                        syncType = "full",
                        attendeeCount = 10
                    )
                }
            val viewModel = SyncViewModel(syncRepository = repo, clock = clock)

            viewModel.syncAttendees()
            viewModel.syncAttendees()
            viewModel.syncAttendees()

            // Allow coroutine to start.
            dispatcher.scheduler.advanceUntilIdle()

            assertThat(repo.callCount).isEqualTo(1)
        }

    @Test
    fun rateLimited_setsState_andBlocksUntilRetryAfter() =
        runTest(dispatcher) {
            val repo =
                RecordingSyncRepository {
                    throw SyncRateLimitedException(
                        message =
                            "Sync is temporarily rate-limited. Please wait a moment before trying again.",
                        retryAfterMillis = 10_000L
                    )
                }
            val viewModel = SyncViewModel(syncRepository = repo, clock = clock)

            viewModel.syncAttendees()
            dispatcher.scheduler.advanceUntilIdle()

            val afterFirst = viewModel.uiState.value
            assertThat(afterFirst.isRateLimited).isTrue()
            assertThat(afterFirst.nextAllowedSyncAtMillis).isNotNull()

            val recordedNextAllowed = afterFirst.nextAllowedSyncAtMillis!!

            // Second tap before nextAllowedSyncAtMillis should be ignored entirely.
            viewModel.syncAttendees()
            dispatcher.scheduler.advanceUntilIdle()
            assertThat(repo.callCount).isEqualTo(1)

            // Move time past nextAllowedSyncAtMillis and allow another attempt.
            val advancedClock =
                Clock.offset(clock, java.time.Duration.ofMillis(11_000L))
            val viewModelWithAdvancedClock =
                SyncViewModel(syncRepository = repo, clock = advancedClock)

            viewModelWithAdvancedClock.syncAttendees()
            dispatcher.scheduler.advanceUntilIdle()

            assertThat(repo.callCount).isEqualTo(2)
        }
}

