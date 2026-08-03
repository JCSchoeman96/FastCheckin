package za.co.voelgoed.fastcheck.feature.support

import za.co.voelgoed.fastcheck.feature.diagnostics.DiagnosticsUiState

class SupportDiagnosticsPresenter {
    fun present(
        diagnosticsUiState: DiagnosticsUiState
    ): SupportDiagnosticsUiState =
        SupportDiagnosticsUiState(
            sections =
                listOf(
                    SupportDiagnosticsSectionUiState(
                        title = "Session and event",
                        items =
                            listOf(
                                SupportDiagnosticsItemUiState("Current event", diagnosticsUiState.currentEvent),
                                SupportDiagnosticsItemUiState("Session state", diagnosticsUiState.authSessionState),
                                SupportDiagnosticsItemUiState("Token state", diagnosticsUiState.tokenExpiryState)
                            )
                    ),
                    SupportDiagnosticsSectionUiState(
                        title = "Attendee sync",
                        items =
                            listOf(
                                SupportDiagnosticsItemUiState("Last attendee sync", diagnosticsUiState.lastAttendeeSyncTime),
                                SupportDiagnosticsItemUiState("Attendee count", diagnosticsUiState.attendeeCount)
                            )
                    ),
                    SupportDiagnosticsSectionUiState(
                        title = "Queue and upload",
                        items =
                            listOf(
                                SupportDiagnosticsItemUiState("Queued locally", diagnosticsUiState.localQueueDepthLabel),
                                SupportDiagnosticsItemUiState("Upload state", diagnosticsUiState.uploadStateLabel),
                                SupportDiagnosticsItemUiState("Latest flush summary", diagnosticsUiState.latestFlushSummary),
                                SupportDiagnosticsItemUiState("Server result summary", diagnosticsUiState.serverResultSummary),
                                SupportDiagnosticsItemUiState("Upload quarantine rows", diagnosticsUiState.quarantinedRowsLabel),
                                SupportDiagnosticsItemUiState("Last upload quarantine", diagnosticsUiState.latestQuarantineLabel)
                            )
                    ),
                    SupportDiagnosticsSectionUiState(
                        title = "Environment",
                        items =
                            listOf(
                                SupportDiagnosticsItemUiState("API target", diagnosticsUiState.apiTargetLabel),
                                SupportDiagnosticsItemUiState("Resolved base URL", diagnosticsUiState.apiBaseUrl)
                            )
                    )
                ) + diagnosticsUiState.parkedBuckets.map { bucket ->
                    val status = when {
                        bucket.conflictCount > 0 || bucket.quarantinedCount > 0 -> "Review required"
                        bucket.state == "AUTH_REQUIRED" -> "Waiting for event login"
                        else -> "Safely parked"
                    }
                    SupportDiagnosticsSectionUiState(
                        title = bucket.eventShortname?.takeIf { it.isNotBlank() }
                            ?: bucket.eventName?.takeIf { it.isNotBlank() }
                            ?: "Event #${bucket.eventId}",
                        items = listOf(
                            SupportDiagnosticsItemUiState("Status", status),
                            SupportDiagnosticsItemUiState("Pending upload", bucket.pendingUploadCount.toString()),
                            SupportDiagnosticsItemUiState("Awaiting reconciliation", bucket.awaitingReconciliationCount.toString()),
                            SupportDiagnosticsItemUiState("Conflicts requiring review", bucket.conflictCount.toString()),
                            SupportDiagnosticsItemUiState("Quarantined evidence", bucket.quarantinedCount.toString()),
                            SupportDiagnosticsItemUiState("Last attendee sync attempt", bucket.lastSyncAttempt ?: "Never"),
                            SupportDiagnosticsItemUiState("Last upload attempt", bucket.lastFlushAttemptAtEpochMillis?.toString() ?: "Never")
                        )
                    )
                }
        )
}
