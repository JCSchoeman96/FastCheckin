package za.co.voelgoed.fastcheck.feature.queue

import javax.inject.Inject
import za.co.voelgoed.fastcheck.domain.model.FlushExecutionStatus
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
}
