package za.co.voelgoed.fastcheck.feature.diagnostics

import java.time.Clock
import javax.inject.Inject
import za.co.voelgoed.fastcheck.core.autoflush.AutoFlushCoordinatorState
import za.co.voelgoed.fastcheck.core.network.ApiEnvironmentConfig
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
        apiEnvironmentConfig: ApiEnvironmentConfig,
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
            apiTargetLabel = apiEnvironmentConfig.target.wireName,
            apiBaseUrl = apiEnvironmentConfig.baseUrl,
            lastAttendeeSyncTime = syncStatus?.lastSuccessfulSyncAt ?: "Never",
            attendeeCount =
                when {
                    syncStatus == null ->
                        "No attendees synced"
                    session != null && session.eventId == syncStatus.eventId ->
                        syncStatus.attendeeCount.toString()
                    else ->
                        "Last synced attendees: ${syncStatus.attendeeCount} (stored locally)"
                },
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
        val replayDuplicate =
            outcomes.count {
                it.outcome == FlushItemOutcome.DUPLICATE && it.reasonCode == "replay_duplicate"
            }
        val businessDuplicate =
            outcomes.count {
                it.outcome == FlushItemOutcome.DUPLICATE && it.reasonCode == "business_duplicate"
            }
        val genericDuplicate =
            outcomes.count {
                it.outcome == FlushItemOutcome.DUPLICATE &&
                    it.reasonCode !in setOf("replay_duplicate", "business_duplicate")
            }
        val paymentInvalid =
            outcomes.count {
                it.outcome == FlushItemOutcome.TERMINAL_ERROR && it.reasonCode == "payment_invalid"
            }
        val genericRejected =
            outcomes.count {
                it.outcome == FlushItemOutcome.TERMINAL_ERROR && it.reasonCode != "payment_invalid"
            }

        val parts = buildList {
            if (confirmed > 0) add("Confirmed: $confirmed")
            if (replayDuplicate > 0) add("Replay duplicate (final): $replayDuplicate")
            if (businessDuplicate > 0) add("Already processed by server: $businessDuplicate")
            if (genericDuplicate > 0) add("Duplicate: $genericDuplicate")
            if (paymentInvalid > 0) add("Payment invalid: $paymentInvalid")
            if (genericRejected > 0) add("Rejected: $genericRejected")
        }

        return if (parts.isEmpty()) {
            // Outcomes exist but none are terminal classifications we can safely summarize.
            "Server outcomes recorded."
        } else {
            parts.joinToString(" | ")
        }
    }
}
