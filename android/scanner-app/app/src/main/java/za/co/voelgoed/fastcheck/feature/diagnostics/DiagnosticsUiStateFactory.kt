package za.co.voelgoed.fastcheck.feature.diagnostics

import java.time.Clock
import javax.inject.Inject
import za.co.voelgoed.fastcheck.core.autoflush.AutoFlushCoordinatorState
import za.co.voelgoed.fastcheck.domain.model.AttendeeSyncStatus
import za.co.voelgoed.fastcheck.domain.model.FlushExecutionStatus
import za.co.voelgoed.fastcheck.domain.model.FlushItemOutcome
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
        latestFlushReport: FlushReport?,
        coordinatorState: AutoFlushCoordinatorState
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

        val uploadStateLabel =
            when {
                coordinatorState.isFlushing ->
                    "Uploading"
                coordinatorState.isRetryScheduled ->
                    "Retry pending (attempt ${coordinatorState.retryAttempt})"
                latestFlushReport?.executionStatus == FlushExecutionStatus.AUTH_EXPIRED ||
                    latestFlushReport?.authExpired == true ->
                    "Auth expired"
                latestFlushReport?.executionStatus == FlushExecutionStatus.RETRYABLE_FAILURE ->
                    "Retry pending"
                else ->
                    "Idle"
            }

        val serverResultSummary =
            buildServerResultSummary(latestFlushReport)

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
            localQueueDepthLabel = "Queued locally: $queueDepth",
            uploadStateLabel = uploadStateLabel,
            serverResultSummary = serverResultSummary,
            latestFlushSummary = latestFlushReport?.summaryMessage ?: "No flush has run yet."
        )
    }

    private fun buildServerResultSummary(report: FlushReport?): String {
        val outcomes = report?.itemOutcomes.orEmpty()
        if (outcomes.isEmpty()) return "No server outcomes yet."

        val confirmed = outcomes.count { it.outcome == FlushItemOutcome.SUCCESS }
        val duplicate = outcomes.count { it.outcome == FlushItemOutcome.DUPLICATE }
        val rejected = outcomes.count { it.outcome == FlushItemOutcome.TERMINAL_ERROR }

        val parts = buildList {
            if (confirmed > 0) add("Confirmed: $confirmed")
            if (duplicate > 0) add("Duplicate: $duplicate")
            if (rejected > 0) add("Rejected: $rejected")
        }

        return if (parts.isEmpty()) {
            // Outcomes exist but none are terminal classifications we can safely summarize.
            "Server outcomes recorded."
        } else {
            parts.joinToString(" | ")
        }
    }
}
