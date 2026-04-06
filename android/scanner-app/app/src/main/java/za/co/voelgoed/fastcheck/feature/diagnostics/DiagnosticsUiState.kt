package za.co.voelgoed.fastcheck.feature.diagnostics

data class DiagnosticsUiState(
    val currentEvent: String = "No active event",
    val authSessionState: String = "Logged out",
    val tokenExpiryState: String = "Unknown",
    val apiTargetLabel: String = "release",
    val apiBaseUrl: String = "Unknown",
    val lastAttendeeSyncTime: String = "Never",
    val attendeeCount: String = "0",
    val localQueueDepthLabel: String = "Queued locally: 0",
    val uploadStateLabel: String = "Idle",
    val serverResultSummary: String = "No server outcomes yet.",
    val latestFlushSummary: String = "No flush has run yet.",
    val quarantinedRowsLabel: String = "Upload quarantine rows: 0",
    val latestQuarantineLabel: String = "Last upload quarantine event: —"
)
