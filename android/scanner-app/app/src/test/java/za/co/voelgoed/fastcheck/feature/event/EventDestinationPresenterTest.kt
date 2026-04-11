package za.co.voelgoed.fastcheck.feature.event

import com.google.common.truth.Truth.assertThat
import java.time.Clock
import java.time.Instant
import java.time.ZoneOffset
import org.junit.Test
import za.co.voelgoed.fastcheck.core.designsystem.semantic.StatusTone
import za.co.voelgoed.fastcheck.core.designsystem.semantic.SyncUiState
import za.co.voelgoed.fastcheck.domain.model.AttendeeSyncStatus
import za.co.voelgoed.fastcheck.domain.model.EventAttendeeCacheMetrics
import za.co.voelgoed.fastcheck.domain.model.ScannerSession
import za.co.voelgoed.fastcheck.feature.event.model.EventOperatorAction
import za.co.voelgoed.fastcheck.feature.queue.QueueUiState
import za.co.voelgoed.fastcheck.feature.sync.BootstrapSyncStatus
import za.co.voelgoed.fastcheck.feature.sync.SyncScreenUiState

class EventDestinationPresenterTest {
    private val presenter =
        EventDestinationPresenter(
            clock = Clock.fixed(Instant.parse("2026-03-13T09:00:00Z"), ZoneOffset.UTC)
        )

    @Test
    fun currentEventIdentityAndLocalMetricsRenderFromCurrentCache() {
        val uiState =
            presenter.present(
                session = session(),
                queueUiState = QueueUiState(),
                syncUiState = SyncScreenUiState(),
                currentEventSyncStatus =
                    AttendeeSyncStatus(
                        eventId = 5,
                        lastServerTime = "2026-03-13T08:50:00Z",
                        lastSuccessfulSyncAt = "2026-03-13T08:50:00Z",
                        syncType = "full",
                        attendeeCount = 120
                    ),
                attendeeMetrics =
                    EventAttendeeCacheMetrics(
                        cachedAttendeeCount = 120,
                        currentlyInsideCount = 34,
                        attendeesWithRemainingCheckinsCount = 86,
                        activeOverlayCount = 3,
                        unresolvedConflictCount = 1
                    )
            )

        assertThat(uiState.headerTitle).isEqualTo("Voelgoed Live")
        assertThat(uiState.headerSubtitle).isEqualTo("Event #5")
        assertThat(uiState.statusChip.text).isEqualTo("Operational")
        assertThat(uiState.attendeeSection.metrics.map { it.value })
            .containsExactly("120", "34", "86", "3", "1")
            .inOrder()
        assertThat(uiState.attendeeSection.supportingText).contains("merged local gate truth")
        assertThat(uiState.attentionBanner?.title).isEqualTo("Reconciliation conflicts need support review")
    }

    @Test
    fun noCurrentEventCacheKeepsAttendeeMetricsUnavailable() {
        val uiState =
            presenter.present(
                session = session(),
                queueUiState = QueueUiState(),
                syncUiState = SyncScreenUiState(bootstrapStatus = BootstrapSyncStatus.Idle),
                currentEventSyncStatus = null,
                attendeeMetrics =
                    EventAttendeeCacheMetrics(
                        cachedAttendeeCount = 0,
                        currentlyInsideCount = 0,
                        attendeesWithRemainingCheckinsCount = 0,
                        activeOverlayCount = 0,
                        unresolvedConflictCount = 0
                    )
            )

        assertThat(uiState.statusChip.text).isEqualTo("Attendee cache pending")
        assertThat(uiState.attendeeSection.metrics.map { it.value })
            .containsExactly("Unavailable", "Unavailable", "Unavailable", "Unavailable", "Unavailable")
            .inOrder()
        assertThat(uiState.activitySection.metrics.first().value).isEqualTo("Unavailable")
    }

    @Test
    fun mismatchedStoredSyncStatusDoesNotRenderAsCurrentEventTruth() {
        val uiState =
            presenter.present(
                session = session(),
                queueUiState = QueueUiState(),
                syncUiState = SyncScreenUiState(),
                currentEventSyncStatus =
                    AttendeeSyncStatus(
                        eventId = 7,
                        lastServerTime = "2026-03-13T08:50:00Z",
                        lastSuccessfulSyncAt = "2026-03-13T08:50:00Z",
                        syncType = "full",
                        attendeeCount = 220
                    ),
                attendeeMetrics =
                    EventAttendeeCacheMetrics(
                        cachedAttendeeCount = 220,
                        currentlyInsideCount = 55,
                        attendeesWithRemainingCheckinsCount = 165,
                        activeOverlayCount = 0,
                        unresolvedConflictCount = 0
                    )
            )

        assertThat(uiState.attendeeSection.metrics.first().value).isEqualTo("Unavailable")
        assertThat(uiState.activitySection.metrics.first().value).isEqualTo("Unavailable")
        assertThat(uiState.attendeeSection.supportingText).contains("successful local sync")
    }

    @Test
    fun offlineBacklogShowsTopAttentionBanner() {
        val uiState =
            presenter.present(
                session = session(),
                queueUiState =
                    QueueUiState(
                        localQueueDepth = 3,
                        uploadSemanticState = SyncUiState.Offline(),
                        uploadStateLabel = "Offline"
                    ),
                syncUiState = SyncScreenUiState(),
                currentEventSyncStatus =
                    AttendeeSyncStatus(
                        eventId = 5,
                        lastServerTime = "2026-03-13T08:50:00Z",
                        lastSuccessfulSyncAt = "2026-03-13T08:50:00Z",
                        syncType = "full",
                        attendeeCount = 120
                    ),
                attendeeMetrics =
                    EventAttendeeCacheMetrics(
                        cachedAttendeeCount = 120,
                        currentlyInsideCount = 34,
                        attendeesWithRemainingCheckinsCount = 86,
                        activeOverlayCount = 2,
                        unresolvedConflictCount = 0
                    )
            )

        assertThat(uiState.statusChip.text).isEqualTo("Uploads paused")
        assertThat(uiState.attentionBanner?.title).isEqualTo("Uploads paused offline")
        assertThat(uiState.attentionBanner?.tone).isEqualTo(StatusTone.Offline)
    }

    @Test
    fun recoveryActionsIncludeManualSyncAndRetryWhenBacklogPartial() {
        val uiState =
            presenter.present(
                session = session(),
                queueUiState =
                    QueueUiState(
                        localQueueDepth = 3,
                        uploadSemanticState = SyncUiState.Partial(backlogRemainingCount = 3),
                        uploadStateLabel = "Partial"
                    ),
                syncUiState = SyncScreenUiState(isSyncing = false),
                currentEventSyncStatus =
                    AttendeeSyncStatus(
                        eventId = 5,
                        lastServerTime = "2026-03-13T08:50:00Z",
                        lastSuccessfulSyncAt = "2026-03-13T08:50:00Z",
                        syncType = "full",
                        attendeeCount = 120
                    ),
                attendeeMetrics =
                    EventAttendeeCacheMetrics(
                        cachedAttendeeCount = 120,
                        currentlyInsideCount = 34,
                        attendeesWithRemainingCheckinsCount = 86,
                        activeOverlayCount = 0,
                        unresolvedConflictCount = 0
                    )
            )

        val actions = uiState.operatorActions.map { it.action }
        assertThat(actions).contains(EventOperatorAction.ManualSync)
        assertThat(actions).contains(EventOperatorAction.RetryUpload)
        assertThat(actions).doesNotContain(EventOperatorAction.Relogin)
    }

    @Test
    fun manualSyncHiddenWhileAttendeeSyncRunning() {
        val uiState =
            presenter.present(
                session = session(),
                queueUiState = QueueUiState(),
                syncUiState = SyncScreenUiState(isSyncing = true),
                currentEventSyncStatus =
                    AttendeeSyncStatus(
                        eventId = 5,
                        lastServerTime = "2026-03-13T08:50:00Z",
                        lastSuccessfulSyncAt = "2026-03-13T08:50:00Z",
                        syncType = "full",
                        attendeeCount = 120
                    ),
                attendeeMetrics =
                    EventAttendeeCacheMetrics(
                        cachedAttendeeCount = 120,
                        currentlyInsideCount = 34,
                        attendeesWithRemainingCheckinsCount = 86,
                        activeOverlayCount = 0,
                        unresolvedConflictCount = 0
                    )
            )

        assertThat(uiState.operatorActions.map { it.action }).doesNotContain(EventOperatorAction.ManualSync)
    }

    @Test
    fun authExpiredBacklogShowsReloginBanner() {
        val uiState =
            presenter.present(
                session = session(),
                queueUiState =
                    QueueUiState(
                        localQueueDepth = 2,
                        uploadSemanticState = SyncUiState.Failed(reason = "Auth expired"),
                        uploadStateLabel = "Auth expired"
                    ),
                syncUiState = SyncScreenUiState(),
                currentEventSyncStatus =
                    AttendeeSyncStatus(
                        eventId = 5,
                        lastServerTime = "2026-03-13T08:50:00Z",
                        lastSuccessfulSyncAt = "2026-03-13T08:50:00Z",
                        syncType = "full",
                        attendeeCount = 120
                    ),
                attendeeMetrics =
                    EventAttendeeCacheMetrics(
                        cachedAttendeeCount = 120,
                        currentlyInsideCount = 34,
                        attendeesWithRemainingCheckinsCount = 86,
                        activeOverlayCount = 1,
                        unresolvedConflictCount = 0
                    )
            )

        assertThat(uiState.statusChip.text).isEqualTo("Re-login required")
        assertThat(uiState.attentionBanner?.title).isEqualTo("Re-login required")
        assertThat(uiState.attentionBanner?.tone).isEqualTo(StatusTone.Destructive)
        val actions = uiState.operatorActions.map { it.action }
        assertThat(actions).contains(EventOperatorAction.Relogin)
        assertThat(actions).doesNotContain(EventOperatorAction.RetryUpload)
    }

    @Test
    fun bootstrapFailureWithoutCacheShowsAttentionBannerNearTop() {
        val uiState =
            presenter.present(
                session = session(),
                queueUiState = QueueUiState(),
                syncUiState =
                    SyncScreenUiState(
                        bootstrapStatus = BootstrapSyncStatus.Failed,
                        errorMessage = "Sync timed out"
                    ),
                currentEventSyncStatus = null,
                attendeeMetrics = null
            )

        assertThat(uiState.attentionBanner?.title).isEqualTo("Attendee cache unavailable")
        assertThat(uiState.attentionBanner?.message).contains("Sync timed out")
        assertThat(uiState.attendeeSection.metrics.map { it.value }.distinct())
            .containsExactly("Unavailable")
    }

    @Test
    fun uploadQuarantineDoesNotReadAsOperationalSuccess() {
        val uiState =
            presenter.present(
                session = session(),
                queueUiState =
                    QueueUiState(
                        localQueueDepth = 0,
                        quarantineCount = 2,
                        quarantineLatestReasonLabel = "UNRECOVERABLE_API_CONTRACT_ERROR"
                    ),
                syncUiState = SyncScreenUiState(),
                currentEventSyncStatus =
                    AttendeeSyncStatus(
                        eventId = 5,
                        lastServerTime = "2026-03-13T08:50:00Z",
                        lastSuccessfulSyncAt = "2026-03-13T08:50:00Z",
                        syncType = "full",
                        attendeeCount = 120
                    ),
                attendeeMetrics =
                    EventAttendeeCacheMetrics(
                        cachedAttendeeCount = 120,
                        currentlyInsideCount = 0,
                        attendeesWithRemainingCheckinsCount = 120,
                        activeOverlayCount = 0,
                        unresolvedConflictCount = 0
                    )
            )

        assertThat(uiState.statusChip.text).isEqualTo("Upload quarantine")
        assertThat(uiState.statusChip.tone).isEqualTo(StatusTone.Warning)
        assertThat(uiState.attentionBanner?.title).isEqualTo("Upload quarantine active")
        assertThat(uiState.queueSection.supportingText).contains("not in that backlog")
        assertThat(uiState.queueSection.metrics.map { it.label })
            .contains("Upload quarantine rows")
    }

    @Test
    fun staleCacheWithSyncFailuresShowsSyncDelayedMessaging() {
        val uiState =
            presenter.present(
                session = session(),
                queueUiState = QueueUiState(),
                syncUiState = SyncScreenUiState(),
                currentEventSyncStatus =
                    AttendeeSyncStatus(
                        eventId = 5,
                        lastServerTime = "2026-03-13T08:00:00Z",
                        lastSuccessfulSyncAt = "2026-03-13T08:00:00Z",
                        syncType = "incremental",
                        attendeeCount = 100,
                        consecutiveFailures = 2
                    ),
                attendeeMetrics =
                    EventAttendeeCacheMetrics(
                        cachedAttendeeCount = 100,
                        currentlyInsideCount = 0,
                        attendeesWithRemainingCheckinsCount = 100,
                        activeOverlayCount = 0,
                        unresolvedConflictCount = 0
                    )
            )

        assertThat(uiState.statusChip.text).isEqualTo("Sync delayed")
        assertThat(uiState.statusMessage).contains("Sync delayed, scanning continues")
    }

    @Test
    fun staleCacheWithIntegrityFailuresOnlyShowsSyncDelayedMessaging() {
        val uiState =
            presenter.present(
                session = session(),
                queueUiState = QueueUiState(),
                syncUiState = SyncScreenUiState(),
                currentEventSyncStatus =
                    AttendeeSyncStatus(
                        eventId = 5,
                        lastServerTime = "2026-03-13T08:00:00Z",
                        lastSuccessfulSyncAt = "2026-03-13T08:00:00Z",
                        syncType = "incremental",
                        attendeeCount = 100,
                        consecutiveFailures = 0,
                        consecutiveIntegrityFailures = 2
                    ),
                attendeeMetrics =
                    EventAttendeeCacheMetrics(
                        cachedAttendeeCount = 100,
                        currentlyInsideCount = 0,
                        attendeesWithRemainingCheckinsCount = 100,
                        activeOverlayCount = 0,
                        unresolvedConflictCount = 0
                    )
            )

        assertThat(uiState.statusChip.text).isEqualTo("Sync delayed")
        assertThat(uiState.statusMessage).contains("Sync delayed, scanning continues")
    }

    @Test
    fun staleCacheWithoutFailuresShowsOlderCacheMessaging() {
        val uiState =
            presenter.present(
                session = session(),
                queueUiState = QueueUiState(),
                syncUiState = SyncScreenUiState(),
                currentEventSyncStatus =
                    AttendeeSyncStatus(
                        eventId = 5,
                        lastServerTime = "2026-03-13T08:00:00Z",
                        lastSuccessfulSyncAt = "2026-03-13T08:00:00Z",
                        syncType = "incremental",
                        attendeeCount = 100,
                        consecutiveFailures = 0
                    ),
                attendeeMetrics =
                    EventAttendeeCacheMetrics(
                        cachedAttendeeCount = 100,
                        currentlyInsideCount = 0,
                        attendeesWithRemainingCheckinsCount = 100,
                        activeOverlayCount = 0,
                        unresolvedConflictCount = 0
                    )
            )

        assertThat(uiState.statusChip.text).isEqualTo("Cache may be old")
        assertThat(uiState.statusMessage).contains("older local sync")
    }

    private fun session(): ScannerSession =
        ScannerSession(
            eventId = 5,
            eventName = "Voelgoed Live",
            expiresInSeconds = 3600,
            authenticatedAtEpochMillis = 1_773_388_800_000,
            expiresAtEpochMillis = 1_773_392_400_000
        )
}
