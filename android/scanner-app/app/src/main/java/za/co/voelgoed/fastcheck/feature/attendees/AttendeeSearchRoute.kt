package za.co.voelgoed.fastcheck.feature.attendees

import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import za.co.voelgoed.fastcheck.core.designsystem.semantic.StatusTone
import za.co.voelgoed.fastcheck.domain.model.AttendeeSyncStatus
import za.co.voelgoed.fastcheck.domain.model.ScannerSession
import za.co.voelgoed.fastcheck.feature.sync.BootstrapSyncStatus
import za.co.voelgoed.fastcheck.feature.sync.SyncScreenUiState
import za.co.voelgoed.fastcheck.feature.sync.SyncViewModel

@Composable
fun AttendeeSearchRoute(
    session: ScannerSession,
    attendeeSearchViewModel: AttendeeSearchViewModel,
    syncViewModel: SyncViewModel,
    modifier: Modifier = Modifier
) {
    val searchUiState by attendeeSearchViewModel.uiState.collectAsState()
    val syncUiState by syncViewModel.uiState.collectAsState()
    val currentEventSyncStatus by syncViewModel.currentEventSyncStatus.collectAsState()

    LaunchedEffect(session.eventId) {
        attendeeSearchViewModel.setEventId(session.eventId)
        syncViewModel.refreshCurrentEventSyncStatus()
        syncViewModel.ensureBootstrapSyncForEvent(session.eventId)
    }

    AttendeeSearchScreen(
        uiState =
            searchUiState.copy(
                syncBanner = buildSyncBanner(syncUiState, currentEventSyncStatus)
            ),
        onQueryChanged = attendeeSearchViewModel::updateQuery,
        onAttendeeSelected = attendeeSearchViewModel::selectAttendee,
        onBackToResults = attendeeSearchViewModel::clearSelection,
        onDismissActionBanner = attendeeSearchViewModel::dismissActionBanner,
        onQueueManualCheckIn = attendeeSearchViewModel::queueManualCheckIn,
        modifier = modifier
    )
}

private fun buildSyncBanner(
    syncUiState: SyncScreenUiState,
    currentEventSyncStatus: AttendeeSyncStatus?
): AttendeeSearchBannerUiModel? =
    when {
        currentEventSyncStatus != null ->
            AttendeeSearchBannerUiModel(
                title = "Local attendee cache ready",
                message = "Search is using ${currentEventSyncStatus.attendeeCount} attendees from the current local sync.",
                tone = StatusTone.Success
            )

        syncUiState.bootstrapStatus == BootstrapSyncStatus.Syncing ->
            AttendeeSearchBannerUiModel(
                title = "Preparing attendee cache",
                message = "Search is waiting for the initial local attendee sync to finish.",
                tone = StatusTone.Info
            )

        syncUiState.bootstrapStatus == BootstrapSyncStatus.Failed ->
            AttendeeSearchBannerUiModel(
                title = "Attendee cache unavailable",
                message = syncUiState.errorMessage ?: "Search needs a successful attendee sync before results can load.",
                tone = StatusTone.Warning
            )

        else -> null
    }
