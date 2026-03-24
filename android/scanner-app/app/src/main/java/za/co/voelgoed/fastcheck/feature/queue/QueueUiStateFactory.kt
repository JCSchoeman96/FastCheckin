package za.co.voelgoed.fastcheck.feature.queue

import javax.inject.Inject
import za.co.voelgoed.fastcheck.domain.model.FlushExecutionStatus
import za.co.voelgoed.fastcheck.domain.model.FlushItemOutcome
import za.co.voelgoed.fastcheck.domain.model.FlushReport
import za.co.voelgoed.fastcheck.domain.model.QueueCreationResult

class QueueUiStateFactory @Inject constructor() {
    fun actionMessageForQueueResult(result: QueueCreationResult): String =
        when (result) {
            is QueueCreationResult.Enqueued ->
                "Queued ${result.pendingScan.ticketCode} for upload."

            QueueCreationResult.ReplaySuppressed ->
                "Local replay suppression ignored a repeated ticket_code inside the 3 second window."

            QueueCreationResult.MissingSessionContext ->
                "Login is required before queued scans can be created."

            QueueCreationResult.InvalidTicketCode ->
                "Ticket code is required."
        }

    fun actionMessageForFlushReport(report: FlushReport): String =
        when (report.executionStatus) {
            FlushExecutionStatus.COMPLETED -> report.summaryMessage
            FlushExecutionStatus.RETRYABLE_FAILURE -> report.summaryMessage
            FlushExecutionStatus.AUTH_EXPIRED -> report.summaryMessage
            FlushExecutionStatus.WORKER_FAILURE -> report.summaryMessage
        }

    fun serverResultHintForFlushReport(report: FlushReport?): String {
        val outcomes = report?.itemOutcomes.orEmpty()
        if (report == null || outcomes.isEmpty()) return "No server outcomes yet."

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
        val rejected =
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
            if (rejected > 0) add("Rejected: $rejected")
            if (retryPending > 0) add("Retry backlog unresolved: $retryPending")
        }

        return if (parts.isEmpty()) {
            "No server outcomes yet."
        } else {
            parts.joinToString(" | ")
        }
    }
}
