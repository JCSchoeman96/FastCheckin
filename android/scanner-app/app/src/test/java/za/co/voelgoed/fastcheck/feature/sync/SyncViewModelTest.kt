package za.co.voelgoed.fastcheck.feature.sync

import com.google.common.truth.Truth.assertThat
import java.time.Clock
import java.time.Duration
import java.time.Instant
import java.time.ZoneOffset
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runCurrent
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
        private val behavior: suspend () -> AttendeeSyncStatus?,
        private val currentStatusProvider: () -> AttendeeSyncStatus? = { null }
    ) : SyncRepository {
        var callCount: Int = 0

        override suspend fun syncAttendees(): AttendeeSyncStatus? {
            callCount += 1
            return behavior()
        }

        override suspend fun currentSyncStatus(): AttendeeSyncStatus? = currentStatusProvider()

        override fun observeLastSyncedStatus(): Flow<AttendeeSyncStatus?> =
            error("Not used in this test")
    }

    @Test
    fun rapidTapsWhileSyncing_doNotTriggerMultipleCalls() = runTest(dispatcher) {
        val repo =
            RecordingSyncRepository(behavior = {
                AttendeeSyncStatus(
                    eventId = 5,
                    lastServerTime = "2026-03-13T08:20:00Z",
                    lastSuccessfulSyncAt = "2026-03-13T08:20:00Z",
                    syncType = "full",
                    attendeeCount = 10
                )
            })
        val viewModel = SyncViewModel(syncRepository = repo, clock = clock)

        viewModel.syncAttendees()
        viewModel.syncAttendees()
        viewModel.syncAttendees()
        advanceUntilIdle()

        assertThat(repo.callCount).isEqualTo(1)
    }

    @Test
    fun rateLimited_setsState_andBlocksUntilRetryAfter() = runTest(dispatcher) {
        val repo =
            RecordingSyncRepository(behavior = {
                throw SyncRateLimitedException(
                    message =
                        "Sync is temporarily rate-limited. Please wait a moment before trying again.",
                    retryAfterMillis = 10_000L
                )
            })
        val viewModel = SyncViewModel(syncRepository = repo, clock = clock)

        viewModel.syncAttendees()
        advanceUntilIdle()

        assertThat(viewModel.uiState.value.isRateLimited).isTrue()
        assertThat(viewModel.uiState.value.nextAllowedSyncAtMillis).isNotNull()

        viewModel.syncAttendees()
        advanceUntilIdle()
        assertThat(repo.callCount).isEqualTo(1)

        val advancedClock = Clock.offset(clock, Duration.ofMillis(11_000L))
        val viewModelWithAdvancedClock =
            SyncViewModel(syncRepository = repo, clock = advancedClock)

        viewModelWithAdvancedClock.syncAttendees()
        advanceUntilIdle()

        assertThat(repo.callCount).isEqualTo(2)
    }

    @Test
    fun authenticatedBootstrapStartsWhenCurrentEventHasNoCache() = runTest(dispatcher) {
        val syncedStatus =
            AttendeeSyncStatus(
                eventId = 7,
                lastServerTime = "2026-03-13T08:20:00Z",
                lastSuccessfulSyncAt = "2026-03-13T08:20:00Z",
                syncType = "full",
                attendeeCount = 42
            )
        val repo = RecordingSyncRepository(behavior = { syncedStatus })
        val viewModel = SyncViewModel(syncRepository = repo, clock = clock)

        viewModel.beginAuthenticatedEventBootstrap(7)
        runCurrent()
        assertThat(repo.callCount).isEqualTo(1)
        advanceUntilIdle()

        assertThat(repo.callCount).isEqualTo(1)
        assertThat(viewModel.currentEventSyncStatus.value).isEqualTo(syncedStatus)
        assertThat(viewModel.uiState.value.bootstrapStatus).isEqualTo(BootstrapSyncStatus.Succeeded)
    }

    @Test
    fun authenticatedBootstrapSkipsWhenCurrentEventMetadataAlreadyExists() = runTest(dispatcher) {
        val existingStatus =
            AttendeeSyncStatus(
                eventId = 9,
                lastServerTime = "2026-03-13T08:20:00Z",
                lastSuccessfulSyncAt = "2026-03-13T08:20:00Z",
                syncType = "incremental",
                attendeeCount = 12
            )
        val repo =
            RecordingSyncRepository(
                behavior = { error("Should not sync") },
                currentStatusProvider = { existingStatus }
            )
        val viewModel = SyncViewModel(syncRepository = repo, clock = clock)

        viewModel.beginAuthenticatedEventBootstrap(9)
        advanceUntilIdle()

        assertThat(repo.callCount).isEqualTo(0)
        assertThat(viewModel.currentEventSyncStatus.value).isEqualTo(existingStatus)
        assertThat(viewModel.uiState.value.bootstrapStatus).isEqualTo(BootstrapSyncStatus.Succeeded)
    }

    @Test
    fun otherEventMetadataDoesNotCountAsCurrentEventReady() = runTest(dispatcher) {
        val otherEventStatus =
            AttendeeSyncStatus(
                eventId = 3,
                lastServerTime = "2026-03-13T08:20:00Z",
                lastSuccessfulSyncAt = "2026-03-13T08:20:00Z",
                syncType = "full",
                attendeeCount = 18
            )
        val targetStatus =
            AttendeeSyncStatus(
                eventId = 8,
                lastServerTime = "2026-03-13T08:25:00Z",
                lastSuccessfulSyncAt = "2026-03-13T08:25:00Z",
                syncType = "full",
                attendeeCount = 30
            )
        val repo =
            RecordingSyncRepository(
                behavior = { targetStatus },
                currentStatusProvider = { otherEventStatus }
            )
        val viewModel = SyncViewModel(syncRepository = repo, clock = clock)

        viewModel.beginAuthenticatedEventBootstrap(8)
        advanceUntilIdle()

        assertThat(repo.callCount).isEqualTo(1)
        assertThat(viewModel.currentEventSyncStatus.value).isEqualTo(targetStatus)
    }

    @Test
    fun bootstrapFailureLeavesFailedStateForRetry() = runTest(dispatcher) {
        val repo =
            RecordingSyncRepository(
                behavior = { throw IllegalStateException("Backend timeout") }
            )
        val viewModel = SyncViewModel(syncRepository = repo, clock = clock)

        viewModel.beginAuthenticatedEventBootstrap(7)
        advanceUntilIdle()

        assertThat(repo.callCount).isEqualTo(1)
        assertThat(viewModel.currentEventSyncStatus.value).isNull()
        assertThat(viewModel.uiState.value.bootstrapStatus).isEqualTo(BootstrapSyncStatus.Failed)
        assertThat(viewModel.uiState.value.bootstrapEventId).isEqualTo(7)
        assertThat(viewModel.uiState.value.errorMessage).isEqualTo("Backend timeout")
    }

    @Test
    fun bootstrapDoesNotRerunUnnecessarilyForSameEventAfterSuccess() = runTest(dispatcher) {
        val syncedStatus =
            AttendeeSyncStatus(
                eventId = 7,
                lastServerTime = "2026-03-13T08:20:00Z",
                lastSuccessfulSyncAt = "2026-03-13T08:20:00Z",
                syncType = "full",
                attendeeCount = 42
            )
        val repo = RecordingSyncRepository(behavior = { syncedStatus })
        val viewModel = SyncViewModel(syncRepository = repo, clock = clock)

        viewModel.beginAuthenticatedEventBootstrap(7)
        advanceUntilIdle()
        viewModel.beginAuthenticatedEventBootstrap(7)
        advanceUntilIdle()

        assertThat(repo.callCount).isEqualTo(1)
        assertThat(viewModel.uiState.value.bootstrapStatus).isEqualTo(BootstrapSyncStatus.Succeeded)
    }

    @Test
    fun resetBootstrapStateClearsCurrentEventSyncStatus() = runTest(dispatcher) {
        val syncedStatus =
            AttendeeSyncStatus(
                eventId = 7,
                lastServerTime = "2026-03-13T08:20:00Z",
                lastSuccessfulSyncAt = "2026-03-13T08:20:00Z",
                syncType = "full",
                attendeeCount = 42
            )
        val repo = RecordingSyncRepository(behavior = { syncedStatus })
        val viewModel = SyncViewModel(syncRepository = repo, clock = clock)

        viewModel.beginAuthenticatedEventBootstrap(7)
        advanceUntilIdle()
        viewModel.resetBootstrapState()

        assertThat(viewModel.currentEventSyncStatus.value).isNull()
        assertThat(viewModel.uiState.value.bootstrapStatus).isEqualTo(BootstrapSyncStatus.Idle)
        assertThat(viewModel.uiState.value.bootstrapEventId).isNull()
    }
}
