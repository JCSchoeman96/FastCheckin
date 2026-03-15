package za.co.voelgoed.fastcheck.feature.diagnostics

data class DiagnosticsUiState(
    val currentEvent: String = "No active event",
    val authSessionState: String = "Logged out",
    val tokenExpiryState: String = "Unknown",
    val lastAttendeeSyncTime: String = "Never",
    val attendeeCount: String = "0",
    val queueDepth: String = "0",
    val latestFlushState: String = "Never",
    val latestFlushSummary: String = "No flush has run yet.",
    val recentOutcomeSummary: String = "No recent flush outcomes."
)
