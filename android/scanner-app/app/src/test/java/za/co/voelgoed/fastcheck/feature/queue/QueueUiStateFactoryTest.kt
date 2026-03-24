package za.co.voelgoed.fastcheck.feature.queue

import com.google.common.truth.Truth.assertThat
import org.junit.Test
import za.co.voelgoed.fastcheck.domain.model.FlushExecutionStatus
import za.co.voelgoed.fastcheck.domain.model.FlushItemOutcome
import za.co.voelgoed.fastcheck.domain.model.FlushItemResult
import za.co.voelgoed.fastcheck.domain.model.FlushReport
import za.co.voelgoed.fastcheck.domain.model.PendingScan
import za.co.voelgoed.fastcheck.domain.model.QueueCreationResult
import za.co.voelgoed.fastcheck.domain.model.ScanDirection

class QueueUiStateFactoryTest {
    private val factory = QueueUiStateFactory()

    @Test
    fun noPersistedFlushReportKeepsHintNeutral() {
        assertThat(factory.serverResultHintForFlushReport(null)).isEqualTo("No server outcomes yet.")
    }

    @Test
    fun plainDuplicateWithoutReplayRefinementStaysBroad() {
        val hint =
            factory.serverResultHintForFlushReport(
                FlushReport(
                    executionStatus = FlushExecutionStatus.COMPLETED,
                    itemOutcomes =
                        listOf(
                            FlushItemResult(
                                idempotencyKey = "idem-1",
                                ticketCode = "VG-1",
                                outcome = FlushItemOutcome.DUPLICATE,
                                message = "Already processed"
                            )
                        ),
                    uploadedCount = 1
                )
            )

        assertThat(hint).isEqualTo("Already processed by server: 1")
        assertThat(hint).doesNotContain("Replay duplicate")
    }

    @Test
    fun retryBacklogHintRemainsUnresolved_notRejected() {
        val hint =
            factory.serverResultHintForFlushReport(
                FlushReport(
                    executionStatus = FlushExecutionStatus.RETRYABLE_FAILURE,
                    itemOutcomes =
                        listOf(
                            FlushItemResult(
                                idempotencyKey = "idem-1",
                                ticketCode = "VG-1",
                                outcome = FlushItemOutcome.RETRYABLE_FAILURE,
                                message = "Temporary server issue"
                            )
                        ),
                    retryableRemainingCount = 1,
                    backlogRemaining = true,
                    summaryMessage = "Retry pending"
                )
            )

        assertThat(hint).isEqualTo("Retry backlog unresolved: 1")
        assertThat(hint).doesNotContain("Rejected")
    }

    @Test
    fun genericRejectedHintDoesNotParseMessageText() {
        val hint =
            factory.serverResultHintForFlushReport(
                FlushReport(
                    executionStatus = FlushExecutionStatus.COMPLETED,
                    itemOutcomes =
                        listOf(
                            FlushItemResult(
                                idempotencyKey = "idem-1",
                                ticketCode = "VG-1",
                                outcome = FlushItemOutcome.TERMINAL_ERROR,
                                message = "Invalid / not found"
                            )
                        ),
                    uploadedCount = 1
                )
            )

        assertThat(hint).isEqualTo("Rejected: 1")
        assertThat(hint).doesNotContain("Invalid")
        assertThat(hint).doesNotContain("not found")
    }

    @Test
    fun manualQueueingMessageRemainsLocalOnly() {
        val message =
            factory.actionMessageForQueueResult(
                QueueCreationResult.Enqueued(
                    PendingScan(
                        eventId = 5,
                        ticketCode = "VG-LOCAL",
                        idempotencyKey = "idem-1",
                        createdAt = 1_773_487_800_000,
                        scannedAt = "2026-03-13T08:30:00Z",
                        direction = ScanDirection.IN,
                        entranceName = "Manual Debug",
                        operatorName = "Operator"
                    )
                )
            )

        assertThat(message).isEqualTo("Queued VG-LOCAL for upload.")
        assertThat(message).doesNotContain("Confirmed")
        assertThat(message).doesNotContain("accepted by server")
    }
}
