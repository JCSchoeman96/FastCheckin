package za.co.voelgoed.fastcheck.feature.diagnostics

import java.time.Clock
import javax.inject.Inject
import za.co.voelgoed.fastcheck.core.autoflush.AutoFlushCoordinatorState
import za.co.voelgoed.fastcheck.core.designsystem.semantic.SyncUiState
import za.co.voelgoed.fastcheck.core.designsystem.semantic.toSyncUiState
import za.co.voelgoed.fastcheck.core.network.ApiEnvironmentConfig
import za.co.voelgoed.fastcheck.domain.model.AttendeeSyncStatus
import za.co.voelgoed.fastcheck.domain.model.FlushItemOutcome
import za.co.voelgoed.fastcheck.domain.model.FlushItemResult
import za.co.voelgoed.fastcheck.domain.model.FlushReport
import za.co.voelgoed.fastcheck.domain.model.QuarantineSummary
import za.co.voelgoed.fastcheck.domain.model.ScannerSession
import za.co.voelgoed.fastcheck.domain.model.SessionState

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
        syncUiState: SyncUiState,
        quarantineCount: Int,
        latestQuarantineSummary: QuarantineSummary?
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

        val serverResultSummary =
            buildServerResultSummary(latestFlushReport)

        val quarantinedRowsLabel =
            if (quarantineCount == 0) {
                "Quarantined rows: None"
            } else {
                "Quarantined rows: $quarantineCount"
            }

        val latestQuarantineLabel =
            if (quarantineCount == 0) {
                "Latest quarantine: —"
            } else {
                val reason = latestQuarantineSummary?.latestReason?.wireValue ?: "UNKNOWN"
                val msg = latestQuarantineSummary?.latestMessage?.trim().orEmpty()
                if (msg.isNotEmpty()) {
                    "Latest quarantine: $reason — $msg"
                } else {
                    "Latest quarantine: $reason"
                }
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
            uploadStateLabel = syncUiState.defaultLabel,
            serverResultSummary = serverResultSummary,
            latestFlushSummary = latestFlushReport?.summaryMessage ?: "No flush has run yet.",
            quarantinedRowsLabel = quarantinedRowsLabel,
            latestQuarantineLabel = latestQuarantineLabel
        )
    }

    @Deprecated(
        message = "Test-only compatibility path. Runtime callers must pass SyncUiState directly.",
        level = DeprecationLevel.WARNING
    )
    fun create(
        apiEnvironmentConfig: ApiEnvironmentConfig,
        session: ScannerSession?,
        tokenPresent: Boolean,
        syncStatus: AttendeeSyncStatus?,
        queueDepth: Int,
        latestFlushReport: FlushReport?,
        coordinatorState: AutoFlushCoordinatorState
    ): DiagnosticsUiState =
        create(
            apiEnvironmentConfig = apiEnvironmentConfig,
            session = session,
            tokenPresent = tokenPresent,
            syncStatus = syncStatus,
            queueDepth = queueDepth,
            latestFlushReport = latestFlushReport,
            syncUiState =
                coordinatorState.toSyncUiState(
                    isOnline = true,
                    latestFlushReport = latestFlushReport,
                    pendingQueueDepth = queueDepth
                ),
            quarantineCount = 0,
            latestQuarantineSummary = null
        )

    private fun buildServerResultSummary(report: FlushReport?): String {
        val outcomes = report?.itemOutcomes.orEmpty()
        if (outcomes.isEmpty()) return "No server outcomes yet."

        val confirmed = outcomes.count { it.outcome == FlushItemOutcome.SUCCESS }
        val replayDuplicate =
            outcomes.count {
                it.outcome == FlushItemOutcome.DUPLICATE && it.reasonCode == "replay_duplicate"
            }
        val alreadyProcessed =
            outcomes.count {
                (it.outcome == FlushItemOutcome.DUPLICATE && it.reasonCode != "replay_duplicate") ||
                    (it.outcome == FlushItemOutcome.TERMINAL_ERROR && it.reasonCode == "business_duplicate")
            }
        val paymentInvalid =
            outcomes.count {
                it.outcome == FlushItemOutcome.TERMINAL_ERROR && it.reasonCode == "payment_invalid"
            }
        val genericRejected =
            outcomes.count {
                it.outcome == FlushItemOutcome.TERMINAL_ERROR &&
                    it.reasonCode !in setOf("payment_invalid", "business_duplicate")
            }
        val retryPending =
            outcomes.count {
                it.outcome == FlushItemOutcome.RETRYABLE_FAILURE
            }

        val parts = buildList {
            if (confirmed > 0) add("Confirmed: $confirmed")
            if (replayDuplicate > 0) add("Replay duplicate (final): $replayDuplicate")
            if (alreadyProcessed > 0) add("Already processed by server: $alreadyProcessed")
            if (paymentInvalid > 0) add("Payment invalid: $paymentInvalid")
            if (genericRejected > 0) add("Rejected: $genericRejected")
            if (retryPending > 0) add("Retry backlog unresolved: $retryPending")
        }

        return if (parts.isEmpty()) {
            "No server outcomes yet."
        } else {
            parts.joinToString(" | ")
        }
    }
}
