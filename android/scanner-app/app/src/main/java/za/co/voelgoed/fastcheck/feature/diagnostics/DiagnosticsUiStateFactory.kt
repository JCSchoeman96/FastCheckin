package za.co.voelgoed.fastcheck.feature.diagnostics

import java.time.Clock
import javax.inject.Inject
import za.co.voelgoed.fastcheck.domain.model.AttendeeSyncStatus
import za.co.voelgoed.fastcheck.domain.model.FlushExecutionStatus
import za.co.voelgoed.fastcheck.domain.model.ScannerSession
import za.co.voelgoed.fastcheck.domain.model.SessionState
import za.co.voelgoed.fastcheck.domain.model.FlushReport

class DiagnosticsUiStateFactory @Inject constructor(
    private val clock: Clock
) {
    fun create(
        session: ScannerSession?,
        tokenPresent: Boolean,
        syncStatus: AttendeeSyncStatus?,
        queueDepth: Int,
        latestFlushReport: FlushReport?
    ): DiagnosticsUiState {
        val nowEpochMillis = clock.millis()
        val sessionState =
            when {
                session == null && !tokenPresent -> SessionState.LOGGED_OUT
                session == null && tokenPresent -> SessionState.INVALID
                session?.expiresAtEpochMillis?.let { it <= nowEpochMillis } == true -> SessionState.EXPIRED
                tokenPresent -> SessionState.ACTIVE
                else -> SessionState.INVALID
            }

        val tokenState =
            when {
                !tokenPresent -> "Missing"
                session == null -> "Unknown"
                session.expiresAtEpochMillis <= nowEpochMillis -> "Expired"
                else -> "Valid"
            }

        return DiagnosticsUiState(
            currentEvent = session?.let { "${it.eventName} (#${it.eventId})" } ?: "No active event",
            authSessionState =
                when (sessionState) {
                    SessionState.LOGGED_OUT -> "Logged out"
                    SessionState.ACTIVE -> "Authenticated"
                    SessionState.EXPIRED -> "Expired"
                    SessionState.INVALID -> "Invalid"
                },
            tokenExpiryState = tokenState,
            lastAttendeeSyncTime = syncStatus?.lastSuccessfulSyncAt ?: "Never",
            attendeeCount = syncStatus?.attendeeCount?.toString() ?: "0",
            queueDepth = queueDepth.toString(),
            latestFlushState =
                when (latestFlushReport?.executionStatus) {
                    null -> "Never"
                    FlushExecutionStatus.COMPLETED -> "Completed"
                    FlushExecutionStatus.RETRYABLE_FAILURE -> "Retry pending"
                    FlushExecutionStatus.AUTH_EXPIRED -> "Re-login required"
                    FlushExecutionStatus.WORKER_FAILURE -> "Worker failure"
                },
            latestFlushSummary = latestFlushReport?.summaryMessage ?: "No flush has run yet.",
            recentOutcomeSummary =
                latestFlushReport
                    ?.itemOutcomes
                    ?.take(3)
                    ?.joinToString(separator = " | ") { outcome ->
                        "${outcome.ticketCode}: ${outcome.outcome.name.lowercase()}"
                    }
                    ?.ifBlank { "No recent flush outcomes." }
                    ?: "No recent flush outcomes."
        )
    }
}
