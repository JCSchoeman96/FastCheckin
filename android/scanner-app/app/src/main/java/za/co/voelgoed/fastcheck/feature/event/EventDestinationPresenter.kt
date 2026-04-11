package za.co.voelgoed.fastcheck.feature.event

import java.time.Clock
import java.time.Duration
import java.time.Instant
import za.co.voelgoed.fastcheck.core.designsystem.semantic.StatusTone
import za.co.voelgoed.fastcheck.core.designsystem.semantic.SyncUiState
import za.co.voelgoed.fastcheck.domain.model.AttendeeSyncStatus
import za.co.voelgoed.fastcheck.domain.model.EventAttendeeCacheMetrics
import za.co.voelgoed.fastcheck.domain.model.ScannerSession
import za.co.voelgoed.fastcheck.feature.event.model.EventOperatorAction
import za.co.voelgoed.fastcheck.feature.event.model.EventOperatorActionUiModel
import za.co.voelgoed.fastcheck.feature.queue.QueueUploadRecoveryVisibility
import za.co.voelgoed.fastcheck.feature.queue.QueueUiState
import za.co.voelgoed.fastcheck.feature.sync.BootstrapSyncStatus
import za.co.voelgoed.fastcheck.feature.sync.SyncScreenUiState

class EventDestinationPresenter(
    private val clock: Clock = Clock.systemUTC()
) {
    fun present(
        session: ScannerSession,
        queueUiState: QueueUiState,
        syncUiState: SyncScreenUiState,
        currentEventSyncStatus: AttendeeSyncStatus?,
        attendeeMetrics: EventAttendeeCacheMetrics?
    ): EventDestinationUiState {
        val currentCacheStatus = currentCacheStatus(session, currentEventSyncStatus)

        return EventDestinationUiState(
            headerTitle = session.eventName,
            headerSubtitle = "Event #${session.eventId}",
            statusChip = statusChipFor(queueUiState, syncUiState, currentCacheStatus, currentEventSyncStatus),
            statusMessage = statusMessageFor(queueUiState, syncUiState, currentCacheStatus, currentEventSyncStatus),
            attentionBanner =
                attentionBannerFor(
                    queueUiState = queueUiState,
                    syncUiState = syncUiState,
                    currentCacheStatus = currentCacheStatus,
                    attendeeMetrics = attendeeMetrics
                ),
            operatorActions = operatorActionsFor(queueUiState = queueUiState, syncUiState = syncUiState),
            attendeeSection =
                attendeeSectionFor(
                    currentCacheStatus = currentCacheStatus,
                    attendeeMetrics = attendeeMetrics,
                    syncUiState = syncUiState,
                    currentEventSyncStatus = currentEventSyncStatus
                ),
            queueSection = queueSectionFor(queueUiState),
            activitySection =
                activitySectionFor(
                    currentCacheStatus = currentCacheStatus,
                    queueUiState = queueUiState,
                    currentEventSyncStatus = currentEventSyncStatus
                )
        )
    }

    private fun statusChipFor(
        queueUiState: QueueUiState,
        syncUiState: SyncScreenUiState,
        currentCacheStatus: CurrentCacheStatus,
        currentEventSyncStatus: AttendeeSyncStatus?
    ): EventStatusChipUiModel =
        when {
            requiresRelogin(queueUiState) ->
                EventStatusChipUiModel("Re-login required", StatusTone.Destructive)

            queueUiState.quarantineCount > 0 ->
                EventStatusChipUiModel("Upload quarantine", StatusTone.Warning)

            uploadsPausedOffline(queueUiState) ->
                EventStatusChipUiModel("Uploads paused", StatusTone.Offline)

            queueUiState.localQueueDepth > 0 && queueUiState.uploadSemanticState is SyncUiState.Syncing ->
                EventStatusChipUiModel("Uploading backlog", StatusTone.Info)

            queueUiState.localQueueDepth > 0 &&
                (queueUiState.uploadSemanticState is SyncUiState.Partial ||
                    queueUiState.uploadSemanticState is SyncUiState.RetryScheduled ||
                    retryableFailure(queueUiState)) ->
                EventStatusChipUiModel("Backlog remaining", StatusTone.Warning)

            currentCacheStatus == CurrentCacheStatus.Unavailable && syncUiState.bootstrapStatus == BootstrapSyncStatus.Syncing ->
                EventStatusChipUiModel("Preparing attendee cache", StatusTone.Info)

            currentCacheStatus == CurrentCacheStatus.Unavailable ->
                EventStatusChipUiModel("Attendee cache pending", StatusTone.Warning)

            currentCacheStatus == CurrentCacheStatus.Stale &&
                (currentEventSyncStatus?.consecutiveFailures ?: 0) > 0 ->
                EventStatusChipUiModel("Sync delayed", StatusTone.Warning)

            currentCacheStatus == CurrentCacheStatus.Stale ->
                EventStatusChipUiModel("Cache may be old", StatusTone.Warning)

            else ->
                EventStatusChipUiModel("Operational", StatusTone.Success)
        }

    private fun statusMessageFor(
        queueUiState: QueueUiState,
        syncUiState: SyncScreenUiState,
        currentCacheStatus: CurrentCacheStatus,
        currentEventSyncStatus: AttendeeSyncStatus?
    ): String =
        when {
            requiresRelogin(queueUiState) ->
                "${queueDepthLabel(queueUiState.localQueueDepth)} cannot upload until the operator signs in again."

            queueUiState.quarantineCount > 0 ->
                "Upload quarantine holds rows that are no longer in the retry backlog. " +
                    "Queued locally counts only scans still waiting for upload; quarantine is separate."

            uploadsPausedOffline(queueUiState) ->
                "${queueDepthLabel(queueUiState.localQueueDepth)} will upload automatically once the device reconnects."

            queueUiState.localQueueDepth > 0 && queueUiState.uploadSemanticState is SyncUiState.Syncing ->
                "Queued scans are uploading while the local event overview remains available."

            queueUiState.localQueueDepth > 0 &&
                queueUiState.uploadSemanticState is SyncUiState.RetryScheduled ->
                "Queued scans are waiting for the next retry while the local event overview stays available."

            queueUiState.localQueueDepth > 0 &&
                queueUiState.uploadSemanticState is SyncUiState.Partial ->
                "Some queued scans still need another upload attempt."

            currentCacheStatus == CurrentCacheStatus.Unavailable &&
                syncUiState.bootstrapStatus == BootstrapSyncStatus.Syncing ->
                "Preparing the first attendee cache for this event."

            currentCacheStatus == CurrentCacheStatus.Unavailable ->
                "This event does not have a current attendee cache yet."

            currentCacheStatus == CurrentCacheStatus.Stale &&
                (currentEventSyncStatus?.consecutiveFailures ?: 0) > 0 ->
                "Sync delayed, scanning continues. Attendee sync is retrying in the background."

            currentCacheStatus == CurrentCacheStatus.Stale ->
                "Attendee totals come from an older local sync and may not reflect the latest backend changes."

            else ->
                "This overview reflects the current event session, local attendee cache, and upload health."
        }

    private fun attentionBannerFor(
        queueUiState: QueueUiState,
        syncUiState: SyncScreenUiState,
        currentCacheStatus: CurrentCacheStatus,
        attendeeMetrics: EventAttendeeCacheMetrics?
    ): EventBannerUiModel? =
        when {
            attendeeMetrics != null && attendeeMetrics.unresolvedConflictCount > 0 ->
                EventBannerUiModel(
                    title = "Reconciliation conflicts need support review",
                    message =
                        "${attendeeMetrics.unresolvedConflictCount} local admission conflict(s) remain active. " +
                            "Affected attendees stay non-admissible on this device until support resolves them.",
                    tone = StatusTone.Warning
                )

            requiresRelogin(queueUiState) ->
                EventBannerUiModel(
                    title = "Re-login required",
                    message = "${queueDepthLabel(queueUiState.localQueueDepth)} cannot upload until the operator signs in again.",
                    tone = StatusTone.Destructive
                )

            queueUiState.quarantineCount > 0 ->
                EventBannerUiModel(
                    title = "Upload quarantine active",
                    message =
                        "${queueUiState.quarantineCount} scan row(s) were set aside after unrecoverable upload errors. " +
                            "They are not in the retry backlog and are not treated as a successful upload.",
                    tone = StatusTone.Warning
                )

            uploadsPausedOffline(queueUiState) ->
                EventBannerUiModel(
                    title = "Uploads paused offline",
                    message = "${queueDepthLabel(queueUiState.localQueueDepth)} will upload automatically when the device reconnects.",
                    tone = StatusTone.Offline
                )

            queueUiState.localQueueDepth > 0 &&
                queueUiState.uploadSemanticState is SyncUiState.RetryScheduled ->
                EventBannerUiModel(
                    title = "Uploads waiting to retry",
                    message = "${queueDepthLabel(queueUiState.localQueueDepth)} still needs another upload attempt.",
                    tone = StatusTone.Warning
                )

            queueUiState.localQueueDepth > 0 &&
                queueUiState.uploadSemanticState is SyncUiState.Partial ->
                EventBannerUiModel(
                    title = "Upload backlog remains",
                    message = "${queueDepthLabel(queueUiState.localQueueDepth)} is still queued locally after the latest upload attempt.",
                    tone = StatusTone.Warning
                )

            currentCacheStatus == CurrentCacheStatus.Unavailable &&
                syncUiState.bootstrapStatus == BootstrapSyncStatus.Failed ->
                EventBannerUiModel(
                    title = "Attendee cache unavailable",
                    message =
                        syncUiState.errorMessage?.takeIf { it.isNotBlank() }
                            ?: "This event still has no local attendee cache, so attendee totals cannot be shown yet.",
                    tone = StatusTone.Warning
                )

            else -> null
        }

    private fun attendeeSectionFor(
        currentCacheStatus: CurrentCacheStatus,
        attendeeMetrics: EventAttendeeCacheMetrics?,
        syncUiState: SyncScreenUiState,
        currentEventSyncStatus: AttendeeSyncStatus?
    ): EventSectionUiModel {
        if (currentCacheStatus == CurrentCacheStatus.Ready || currentCacheStatus == CurrentCacheStatus.Stale) {
            val syncStatus = requireNotNull(currentEventSyncStatus)
            return EventSectionUiModel(
                title = "Attendee cache",
                supportingText =
                    if (attendeeMetrics == null) {
                        "Using ${syncStatus.attendeeCount} attendees from the latest local sync. Derived counts are still loading from the local attendee cache."
                    } else {
                        "Using ${syncStatus.attendeeCount} attendees from the latest server sync. Derived counts below come from merged local gate truth, including unresolved admission overlays."
                    },
                metrics =
                    listOf(
                        EventMetricUiModel("Total attendees", syncStatus.attendeeCount.toString()),
                        EventMetricUiModel(
                            "Currently inside",
                            attendeeMetrics?.currentlyInsideCount?.toString() ?: "Unavailable"
                        ),
                        EventMetricUiModel(
                            "With check-ins remaining",
                            attendeeMetrics?.attendeesWithRemainingCheckinsCount?.toString() ?: "Unavailable"
                        ),
                        EventMetricUiModel(
                            "Active local overlays",
                            attendeeMetrics?.activeOverlayCount?.toString() ?: "Unavailable"
                        ),
                        EventMetricUiModel(
                            "Unresolved conflicts",
                            attendeeMetrics?.unresolvedConflictCount?.toString() ?: "Unavailable"
                        )
                    )
            )
        }

        val unavailableText =
            when (syncUiState.bootstrapStatus) {
                BootstrapSyncStatus.Syncing ->
                    "Preparing the attendee cache for this event. Totals will appear after the first successful sync."

                BootstrapSyncStatus.Failed ->
                    "This event does not have a current attendee cache yet, so attendee totals remain unavailable."

                else ->
                    "Attendee totals will appear after this event has a successful local sync."
            }

        return EventSectionUiModel(
            title = "Attendee cache",
            supportingText = unavailableText,
            metrics =
                listOf(
                    EventMetricUiModel("Total attendees", "Unavailable"),
                    EventMetricUiModel("Currently inside", "Unavailable"),
                    EventMetricUiModel("With check-ins remaining", "Unavailable"),
                    EventMetricUiModel("Active local overlays", "Unavailable"),
                    EventMetricUiModel("Unresolved conflicts", "Unavailable")
                )
        )
    }

    private fun queueSectionFor(queueUiState: QueueUiState): EventSectionUiModel {
        val quarantineMetrics =
            if (queueUiState.quarantineCount == 0) {
                listOf(EventMetricUiModel("Upload quarantine rows", "None"))
            } else {
                listOf(
                    EventMetricUiModel("Upload quarantine rows", queueUiState.quarantineCount.toString()),
                    EventMetricUiModel(
                        "Last quarantine reason",
                        queueUiState.quarantineLatestReasonLabel ?: "Unknown"
                    )
                )
            }
        return EventSectionUiModel(
            title = "Queue and upload health",
            supportingText =
                "Queued locally is the retry backlog still waiting for upload. " +
                    "Upload quarantine rows are not in that backlog — they were set aside after unrecoverable errors. " +
                    "Upload state reflects the flush coordinator.",
            metrics =
                buildList {
                    add(EventMetricUiModel("Queued locally", queueDepthValue(queueUiState.localQueueDepth)))
                    add(EventMetricUiModel("Upload state", queueUiState.uploadStateLabel))
                    add(EventMetricUiModel("Server outcomes", queueUiState.serverResultHint))
                    addAll(quarantineMetrics)
                }
        )
    }

    private fun activitySectionFor(
        currentCacheStatus: CurrentCacheStatus,
        queueUiState: QueueUiState,
        currentEventSyncStatus: AttendeeSyncStatus?
    ): EventSectionUiModel {
        val lastSyncValue =
            when (currentCacheStatus) {
                CurrentCacheStatus.Ready,
                CurrentCacheStatus.Stale ->
                    currentEventSyncStatus?.lastSuccessfulSyncAt ?: "Unavailable"

                CurrentCacheStatus.Unavailable ->
                    "Unavailable"
            }

        return EventSectionUiModel(
            title = "Recent activity",
            supportingText = "Recent sync and flush summaries stay read-only on this screen.",
            metrics =
                listOf(
                    EventMetricUiModel("Last attendee sync", lastSyncValue),
                    EventMetricUiModel("Last flush summary", queueUiState.latestFlushSummary),
                    EventMetricUiModel("Latest server summary", queueUiState.serverResultHint)
                )
        )
    }

    private fun uploadsPausedOffline(queueUiState: QueueUiState): Boolean =
        queueUiState.localQueueDepth > 0 && queueUiState.uploadSemanticState is SyncUiState.Offline

    private fun requiresRelogin(queueUiState: QueueUiState): Boolean =
        queueUiState.localQueueDepth > 0 &&
            (queueUiState.uploadSemanticState as? SyncUiState.Failed)?.reason == "Auth expired"

    private fun retryableFailure(queueUiState: QueueUiState): Boolean =
        queueUiState.localQueueDepth > 0 &&
            queueUiState.uploadSemanticState is SyncUiState.Failed &&
            !requiresRelogin(queueUiState)

    private fun operatorActionsFor(
        queueUiState: QueueUiState,
        syncUiState: SyncScreenUiState
    ): List<EventOperatorActionUiModel> {
        val actions = mutableListOf<EventOperatorActionUiModel>()
        if (!syncUiState.isSyncing) {
            actions.add(
                EventOperatorActionUiModel(
                    label = "Sync attendee list",
                    action = EventOperatorAction.ManualSync
                )
            )
        }
        if (
            QueueUploadRecoveryVisibility.shouldShowRetryUpload(
                queueUiState.localQueueDepth,
                queueUiState.uploadSemanticState
            )
        ) {
            actions.add(
                EventOperatorActionUiModel(
                    label = "Retry upload",
                    action = EventOperatorAction.RetryUpload
                )
            )
        }
        if (requiresRelogin(queueUiState)) {
            actions.add(
                EventOperatorActionUiModel(
                    label = "Re-login",
                    action = EventOperatorAction.Relogin
                )
            )
        }
        return actions
    }

    private fun currentCacheStatus(
        session: ScannerSession,
        currentEventSyncStatus: AttendeeSyncStatus?
    ): CurrentCacheStatus {
        val syncStatus = currentEventSyncStatus ?: return CurrentCacheStatus.Unavailable
        if (syncStatus.eventId != session.eventId) return CurrentCacheStatus.Unavailable
        return if (isStale(syncStatus)) CurrentCacheStatus.Stale else CurrentCacheStatus.Ready
    }

    private fun queueDepthLabel(queueDepth: Int): String =
        when (queueDepth) {
            0 -> "No scans are queued locally"
            1 -> "1 scan is queued locally"
            else -> "$queueDepth scans are queued locally"
        }

    private fun queueDepthValue(queueDepth: Int): String =
        when (queueDepth) {
            0 -> "None"
            1 -> "1 scan"
            else -> "$queueDepth scans"
        }

    private fun isStale(syncStatus: AttendeeSyncStatus): Boolean {
        val timestamp = syncStatus.lastSuccessfulSyncAt ?: return false
        val syncedAt =
            runCatching { Instant.parse(timestamp) }
                .getOrNull()
                ?: return false

        return Duration.between(syncedAt, clock.instant()) > STALE_SYNC_THRESHOLD
    }

    private enum class CurrentCacheStatus {
        Ready,
        Stale,
        Unavailable
    }

    private companion object {
        val STALE_SYNC_THRESHOLD: Duration = Duration.ofMinutes(30)
    }
}
