package za.co.voelgoed.fastcheck.feature.event

import java.time.Clock
import java.time.Duration
import java.time.Instant
import za.co.voelgoed.fastcheck.core.designsystem.semantic.StatusTone
import za.co.voelgoed.fastcheck.core.designsystem.semantic.SyncUiState
import za.co.voelgoed.fastcheck.domain.model.AttendeeSyncStatus
import za.co.voelgoed.fastcheck.domain.model.EventAttendeeCacheMetrics
import za.co.voelgoed.fastcheck.domain.model.ScannerSession
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
            statusChip = statusChipFor(queueUiState, syncUiState, currentCacheStatus),
            statusMessage = statusMessageFor(queueUiState, syncUiState, currentCacheStatus),
            attentionBanner = attentionBannerFor(queueUiState, syncUiState, currentCacheStatus),
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
        currentCacheStatus: CurrentCacheStatus
    ): EventStatusChipUiModel =
        when {
            requiresRelogin(queueUiState) ->
                EventStatusChipUiModel("Re-login required", StatusTone.Destructive)

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

            currentCacheStatus == CurrentCacheStatus.Stale ->
                EventStatusChipUiModel("Cache may be old", StatusTone.Warning)

            else ->
                EventStatusChipUiModel("Operational", StatusTone.Success)
        }

    private fun statusMessageFor(
        queueUiState: QueueUiState,
        syncUiState: SyncScreenUiState,
        currentCacheStatus: CurrentCacheStatus
    ): String =
        when {
            requiresRelogin(queueUiState) ->
                "${queueDepthLabel(queueUiState.localQueueDepth)} cannot upload until the operator signs in again."

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

            currentCacheStatus == CurrentCacheStatus.Stale ->
                "Attendee totals come from an older local sync and may not reflect the latest backend changes."

            else ->
                "This overview reflects the current event session, local attendee cache, and upload health."
        }

    private fun attentionBannerFor(
        queueUiState: QueueUiState,
        syncUiState: SyncScreenUiState,
        currentCacheStatus: CurrentCacheStatus
    ): EventBannerUiModel? =
        when {
            requiresRelogin(queueUiState) ->
                EventBannerUiModel(
                    title = "Re-login required",
                    message = "${queueDepthLabel(queueUiState.localQueueDepth)} cannot upload until the operator signs in again.",
                    tone = StatusTone.Destructive
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
                        "Using ${syncStatus.attendeeCount} attendees from the latest local sync. Derived counts below come from the local attendee cache and are not live backend occupancy."
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
                    EventMetricUiModel("With check-ins remaining", "Unavailable")
                )
        )
    }

    private fun queueSectionFor(queueUiState: QueueUiState): EventSectionUiModel =
        EventSectionUiModel(
            title = "Queue and upload health",
            supportingText = "Upload state reflects current queue health. Queue depth remains local durable truth until the backend confirms uploads.",
            metrics =
                listOf(
                    EventMetricUiModel("Queued locally", queueDepthValue(queueUiState.localQueueDepth)),
                    EventMetricUiModel("Upload state", queueUiState.uploadStateLabel),
                    EventMetricUiModel("Server outcomes", queueUiState.serverResultHint)
                )
        )

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
