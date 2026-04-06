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
                                SupportDiagnosticsItemUiState("Quarantined rows", diagnosticsUiState.quarantinedRowsLabel),
                                SupportDiagnosticsItemUiState("Latest quarantine", diagnosticsUiState.latestQuarantineLabel)
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
                )
        )
}
