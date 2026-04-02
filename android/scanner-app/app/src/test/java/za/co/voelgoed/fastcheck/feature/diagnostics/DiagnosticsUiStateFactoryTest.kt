@file:Suppress("DEPRECATION")

package za.co.voelgoed.fastcheck.feature.diagnostics

import com.google.common.truth.Truth.assertThat
import java.time.Clock
import java.time.Instant
import java.time.ZoneOffset
import org.junit.Test
import za.co.voelgoed.fastcheck.core.autoflush.AutoFlushCoordinatorState
import za.co.voelgoed.fastcheck.core.network.ApiEnvironmentConfig
import za.co.voelgoed.fastcheck.core.network.ApiTarget
import za.co.voelgoed.fastcheck.domain.model.AttendeeSyncStatus
import za.co.voelgoed.fastcheck.domain.model.FlushExecutionStatus
import za.co.voelgoed.fastcheck.domain.model.FlushItemOutcome
import za.co.voelgoed.fastcheck.domain.model.FlushItemResult
import za.co.voelgoed.fastcheck.domain.model.FlushReport
import za.co.voelgoed.fastcheck.domain.model.ScannerSession

class DiagnosticsUiStateFactoryTest {
    private val clock = Clock.fixed(Instant.parse("2026-03-13T08:30:00Z"), ZoneOffset.UTC)
    private val factory = DiagnosticsUiStateFactory(clock)
    private val apiEnvironmentConfig =
        ApiEnvironmentConfig(
            target = ApiTarget.EMULATOR,
            baseUrl = "http://10.0.2.2:4000/"
        )

    @Test
    fun derivesLoggedOutStateWithoutSessionOrToken() {
        val state =
            factory.create(
                apiEnvironmentConfig = apiEnvironmentConfig,
                session = null,
                tokenPresent = false,
                syncStatus = null,
                queueDepth = 0,
                latestFlushReport = null,
                coordinatorState = AutoFlushCoordinatorState()
            )

        assertThat(state.currentEvent).isEqualTo("No active event")
        assertThat(state.authSessionState).isEqualTo("Logged out")
        assertThat(state.tokenExpiryState).isEqualTo("Missing")
        assertThat(state.apiTargetLabel).isEqualTo("emulator")
        assertThat(state.apiBaseUrl).isEqualTo("http://10.0.2.2:4000/")
        assertThat(state.lastAttendeeSyncTime).isEqualTo("Never")
        assertThat(state.attendeeCount).isEqualTo("No attendees synced")
        assertThat(state.uploadStateLabel).isEqualTo("Idle")
    }

    @Test
    fun derivesAuthenticatedStateAndQueueDiagnostics() {
        val state =
            factory.create(
                apiEnvironmentConfig = apiEnvironmentConfig,
                session =
                    ScannerSession(
                        eventId = 5,
                        eventName = "Voelgoed Live",
                        expiresInSeconds = 3600,
                        authenticatedAtEpochMillis = 1_773_388_800_000,
                        expiresAtEpochMillis = 1_773_392_400_000
                    ),
                tokenPresent = true,
                syncStatus =
                    AttendeeSyncStatus(
                        eventId = 5,
                        lastServerTime = "2026-03-13T08:20:00Z",
                        lastSuccessfulSyncAt = "2026-03-13T08:20:00Z",
                        syncType = "incremental",
                        attendeeCount = 42
                    ),
                queueDepth = 3,
                latestFlushReport =
                    FlushReport(
                        executionStatus = FlushExecutionStatus.AUTH_EXPIRED,
                        itemOutcomes =
                            listOf(
                                FlushItemResult(
                                    idempotencyKey = "idem-1",
                                    ticketCode = "VG-100",
                                    outcome = FlushItemOutcome.AUTH_EXPIRED,
                                    message = "Login required"
                                )
                            ),
                        uploadedCount = 0,
                        retryableRemainingCount = 3,
                        authExpired = true,
                        backlogRemaining = true,
                        summaryMessage = "Flush stopped. Session expired and manual login is required."
                    ),
                coordinatorState = AutoFlushCoordinatorState()
            )

        assertThat(state.currentEvent).isEqualTo("Voelgoed Live (#5)")
        assertThat(state.authSessionState).isEqualTo("Authenticated")
        assertThat(state.tokenExpiryState).isEqualTo("Valid")
        assertThat(state.attendeeCount).isEqualTo("42")
        assertThat(state.localQueueDepthLabel).isEqualTo("Queued locally: 3")
        assertThat(state.uploadStateLabel).isEqualTo("Auth expired")
    }

    @Test
    fun sessionMissingButLocalSyncMetadataExists_showsLastSyncedAttendees_notZero() {
        val state =
            factory.create(
                apiEnvironmentConfig = apiEnvironmentConfig,
                session = null,
                tokenPresent = false,
                syncStatus =
                    AttendeeSyncStatus(
                        eventId = 5,
                        lastServerTime = "2026-03-13T08:20:00Z",
                        lastSuccessfulSyncAt = "2026-03-13T08:20:00Z",
                        syncType = "full",
                        attendeeCount = 1234
                    ),
                queueDepth = 0,
                latestFlushReport = null,
                coordinatorState = AutoFlushCoordinatorState()
            )

        assertThat(state.currentEvent).isEqualTo("No active event")
        assertThat(state.attendeeCount).contains("Last synced attendees: 1234")
        assertThat(state.attendeeCount).contains("stored locally")
    }

    @Test
    fun duplicatesWithoutReplayRefinementUseBroaderAlreadyProcessedWording() {
        val state =
            factory.create(
                apiEnvironmentConfig = apiEnvironmentConfig,
                session = null,
                tokenPresent = false,
                syncStatus = null,
                queueDepth = 0,
                latestFlushReport =
                    FlushReport(
                        executionStatus = FlushExecutionStatus.COMPLETED,
                        itemOutcomes =
                            listOf(
                                FlushItemResult(
                                    idempotencyKey = "idem-1",
                                    ticketCode = "VG-1",
                                    outcome = FlushItemOutcome.DUPLICATE,
                                    message = "Already processed",
                                    reasonCode = "business_duplicate"
                                ),
                                FlushItemResult(
                                    idempotencyKey = "idem-2",
                                    ticketCode = "VG-2",
                                    outcome = FlushItemOutcome.DUPLICATE,
                                    message = "Already processed"
                                ),
                                FlushItemResult(
                                    idempotencyKey = "idem-3",
                                    ticketCode = "VG-3",
                                    outcome = FlushItemOutcome.TERMINAL_ERROR,
                                    message = "Already processed",
                                    reasonCode = "business_duplicate"
                                )
                            )
                    ),
                coordinatorState = AutoFlushCoordinatorState()
            )

        assertThat(state.serverResultSummary).contains("Already processed by server: 3")
        assertThat(state.serverResultSummary).doesNotContain("Duplicate:")
        assertThat(state.serverResultSummary).doesNotContain("Replay duplicate")
    }

    @Test
    fun paymentInvalidSummaryOnlyShownWhenReasonCodeExists() {
        val state =
            factory.create(
                apiEnvironmentConfig = apiEnvironmentConfig,
                session = null,
                tokenPresent = false,
                syncStatus = null,
                queueDepth = 0,
                latestFlushReport =
                    FlushReport(
                        executionStatus = FlushExecutionStatus.COMPLETED,
                        itemOutcomes =
                            listOf(
                                FlushItemResult(
                                    idempotencyKey = "idem-1",
                                    ticketCode = "VG-1",
                                    outcome = FlushItemOutcome.TERMINAL_ERROR,
                                    message = "Payment required",
                                    reasonCode = "payment_invalid"
                                ),
                                FlushItemResult(
                                    idempotencyKey = "idem-2",
                                    ticketCode = "VG-2",
                                    outcome = FlushItemOutcome.TERMINAL_ERROR,
                                    message = "Invalid / not found"
                                )
                            )
                    ),
                coordinatorState = AutoFlushCoordinatorState()
            )

        assertThat(state.serverResultSummary).contains("Payment invalid: 1")
        assertThat(state.serverResultSummary).contains("Rejected: 1")
        assertThat(state.serverResultSummary).doesNotContain("Invalid")
        assertThat(state.serverResultSummary).doesNotContain("not found")
    }

    @Test
    fun genericDuplicateWithoutReplayReasonStaysBroaderThanReplayFinalWording() {
        val state =
            factory.create(
                apiEnvironmentConfig = apiEnvironmentConfig,
                session = null,
                tokenPresent = false,
                syncStatus = null,
                queueDepth = 0,
                latestFlushReport =
                    FlushReport(
                        executionStatus = FlushExecutionStatus.COMPLETED,
                        itemOutcomes =
                            listOf(
                                FlushItemResult(
                                    idempotencyKey = "idem-1",
                                    ticketCode = "VG-1",
                                    outcome = FlushItemOutcome.DUPLICATE,
                                    message = "Already processed"
                                ),
                                FlushItemResult(
                                    idempotencyKey = "idem-2",
                                    ticketCode = "VG-2",
                                    outcome = FlushItemOutcome.TERMINAL_ERROR,
                                    message = "Some backend error"
                                )
                            )
                    ),
                coordinatorState = AutoFlushCoordinatorState()
            )

        assertThat(state.serverResultSummary).contains("Already processed by server: 1")
        assertThat(state.serverResultSummary).contains("Rejected: 1")
        assertThat(state.serverResultSummary).doesNotContain("Replay duplicate")
        assertThat(state.serverResultSummary).doesNotContain("Payment invalid")
    }

    @Test
    fun retryBacklogRemainsClearlyUnresolved_notRejected() {
        val state =
            factory.create(
                apiEnvironmentConfig = apiEnvironmentConfig,
                session = null,
                tokenPresent = false,
                syncStatus = null,
                queueDepth = 2,
                latestFlushReport =
                    FlushReport(
                        executionStatus = FlushExecutionStatus.RETRYABLE_FAILURE,
                        itemOutcomes =
                            listOf(
                                FlushItemResult(
                                    idempotencyKey = "idem-1",
                                    ticketCode = "VG-1",
                                    outcome = FlushItemOutcome.RETRYABLE_FAILURE,
                                    message = "Temporary error"
                                ),
                                FlushItemResult(
                                    idempotencyKey = "idem-2",
                                    ticketCode = "VG-2",
                                    outcome = FlushItemOutcome.RETRYABLE_FAILURE,
                                    message = "Temporary error"
                                )
                            ),
                        retryableRemainingCount = 2,
                        backlogRemaining = true,
                        summaryMessage = "Retry pending"
                    ),
                coordinatorState = AutoFlushCoordinatorState()
            )

        assertThat(state.serverResultSummary).contains("Retry backlog unresolved: 2")
        assertThat(state.serverResultSummary).doesNotContain("Rejected")
    }

    @Test
    fun queuedLocallyWithoutFlushResult_hidesServerOutcomes() {
        val state =
            factory.create(
                apiEnvironmentConfig = apiEnvironmentConfig,
                session = null,
                tokenPresent = false,
                syncStatus = null,
                queueDepth = 12,
                latestFlushReport = null,
                coordinatorState = AutoFlushCoordinatorState()
            )

        assertThat(state.localQueueDepthLabel).isEqualTo("Queued locally: 12")
        assertThat(state.serverResultSummary).isEqualTo("No server outcomes yet.")
    }

    @Test
    fun uploadingWhileQueueExists_setsUploadingState() {
        val state =
            factory.create(
                apiEnvironmentConfig = apiEnvironmentConfig,
                session = null,
                tokenPresent = false,
                syncStatus = null,
                queueDepth = 4,
                latestFlushReport = null,
                coordinatorState = AutoFlushCoordinatorState(isFlushing = true)
            )

        assertThat(state.uploadStateLabel).isEqualTo("Uploading")
        assertThat(state.localQueueDepthLabel).isEqualTo("Queued locally: 4")
    }

    @Test
    fun retryPendingWithMetadata_includesAttempt() {
        val state =
            factory.create(
                apiEnvironmentConfig = apiEnvironmentConfig,
                session = null,
                tokenPresent = false,
                syncStatus = null,
                queueDepth = 1,
                latestFlushReport = null,
                coordinatorState =
                    AutoFlushCoordinatorState(
                        isRetryScheduled = true,
                        retryAttempt = 2,
                        nextRetryAtEpochMs = 1_777_777_777_777
                    )
            )

        assertThat(state.uploadStateLabel).contains("attempt 2")
    }

    @Test
    fun uploadingTakesPrecedenceOverAuthExpired() {
        val state =
            factory.create(
                apiEnvironmentConfig = apiEnvironmentConfig,
                session = null,
                tokenPresent = false,
                syncStatus = null,
                queueDepth = 1,
                latestFlushReport =
                    FlushReport(
                        executionStatus = FlushExecutionStatus.AUTH_EXPIRED,
                        authExpired = true,
                        summaryMessage = "Auth expired"
                    ),
                coordinatorState = AutoFlushCoordinatorState(isFlushing = true)
            )

        assertThat(state.uploadStateLabel).isEqualTo("Uploading")
    }

    @Test
    fun retryPendingTakesPrecedenceOverAuthExpired() {
        val state =
            factory.create(
                apiEnvironmentConfig = apiEnvironmentConfig,
                session = null,
                tokenPresent = false,
                syncStatus = null,
                queueDepth = 1,
                latestFlushReport =
                    FlushReport(
                        executionStatus = FlushExecutionStatus.AUTH_EXPIRED,
                        authExpired = true,
                        summaryMessage = "Auth expired"
                    ),
                coordinatorState =
                    AutoFlushCoordinatorState(
                        isRetryScheduled = true,
                        retryAttempt = 3
                    )
            )

        assertThat(state.uploadStateLabel).contains("Retry pending")
    }

    @Test
    fun serverResultShownOnlyFromPersistedOutcomes_andMessageIsNotParsed() {
        val state =
            factory.create(
                apiEnvironmentConfig = apiEnvironmentConfig,
                session = null,
                tokenPresent = false,
                syncStatus = null,
                queueDepth = 0,
                latestFlushReport =
                    FlushReport(
                        executionStatus = FlushExecutionStatus.COMPLETED,
                        itemOutcomes =
                            listOf(
                                FlushItemResult(
                                    idempotencyKey = "idem-1",
                                    ticketCode = "VG-1",
                                    outcome = FlushItemOutcome.SUCCESS,
                                    message = "OK"
                                ),
                                FlushItemResult(
                                    idempotencyKey = "idem-2",
                                    ticketCode = "VG-2",
                                    outcome = FlushItemOutcome.DUPLICATE,
                                    message = "Already scanned",
                                    reasonCode = "business_duplicate"
                                ),
                                FlushItemResult(
                                    idempotencyKey = "idem-3",
                                    ticketCode = "VG-3",
                                    outcome = FlushItemOutcome.TERMINAL_ERROR,
                                    message = "Invalid / not found",
                                    reasonCode = "payment_invalid"
                                )
                            ),
                        uploadedCount = 3
                    ),
                coordinatorState = AutoFlushCoordinatorState()
            )

        assertThat(state.serverResultSummary).contains("Confirmed: 1")
        assertThat(state.serverResultSummary).contains("Already processed by server: 1")
        assertThat(state.serverResultSummary).contains("Payment invalid: 1")
        // No message parsing: we never surface "Invalid / not found" as a structured classification.
        assertThat(state.serverResultSummary).doesNotContain("Invalid")
        assertThat(state.serverResultSummary).doesNotContain("not found")
    }

    @Test
    fun replayDuplicateSummaryOnlyShownWhenFinalReasonCodeExists() {
        val state =
            factory.create(
                apiEnvironmentConfig = apiEnvironmentConfig,
                session = null,
                tokenPresent = false,
                syncStatus = null,
                queueDepth = 0,
                latestFlushReport =
                    FlushReport(
                        executionStatus = FlushExecutionStatus.COMPLETED,
                        itemOutcomes =
                            listOf(
                                FlushItemResult(
                                    idempotencyKey = "idem-1",
                                    ticketCode = "VG-1",
                                    outcome = FlushItemOutcome.DUPLICATE,
                                    message = "Already processed",
                                    reasonCode = "replay_duplicate"
                                ),
                                FlushItemResult(
                                    idempotencyKey = "idem-2",
                                    ticketCode = "VG-2",
                                    outcome = FlushItemOutcome.DUPLICATE,
                                    message = "Already processed"
                                )
                            )
                    ),
                coordinatorState = AutoFlushCoordinatorState()
            )

        assertThat(state.serverResultSummary).contains("Replay duplicate (final): 1")
        assertThat(state.serverResultSummary).contains("Already processed by server: 1")
    }
}
