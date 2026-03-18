package za.co.voelgoed.fastcheck.feature.diagnostics

import com.google.common.truth.Truth.assertThat
import java.time.Clock
import java.time.Instant
import java.time.ZoneOffset
import org.junit.Test
import za.co.voelgoed.fastcheck.core.autoflush.AutoFlushCoordinatorState
import za.co.voelgoed.fastcheck.domain.model.AttendeeSyncStatus
import za.co.voelgoed.fastcheck.domain.model.FlushExecutionStatus
import za.co.voelgoed.fastcheck.domain.model.FlushItemOutcome
import za.co.voelgoed.fastcheck.domain.model.FlushItemResult
import za.co.voelgoed.fastcheck.domain.model.FlushReport
import za.co.voelgoed.fastcheck.domain.model.ScannerSession

class DiagnosticsUiStateFactoryTest {
    private val clock = Clock.fixed(Instant.parse("2026-03-13T08:30:00Z"), ZoneOffset.UTC)
    private val factory = DiagnosticsUiStateFactory(clock)

    @Test
    fun derivesLoggedOutStateWithoutSessionOrToken() {
        val state =
            factory.create(
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
        assertThat(state.lastAttendeeSyncTime).isEqualTo("Never")
        assertThat(state.attendeeCount).isEqualTo("No attendees synced")
        assertThat(state.uploadStateLabel).isEqualTo("Idle")
    }

    @Test
    fun derivesAuthenticatedStateAndQueueDiagnostics() {
        val state =
            factory.create(
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
    fun queuedLocallyWithoutFlushResult_hidesServerOutcomes() {
        val state =
            factory.create(
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
    fun serverResultShownOnlyFromPersistedOutcomes_andTerminalErrorIsGeneric() {
        val state =
            factory.create(
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
                                    message = "Already scanned"
                                ),
                                FlushItemResult(
                                    idempotencyKey = "idem-3",
                                    ticketCode = "VG-3",
                                    outcome = FlushItemOutcome.TERMINAL_ERROR,
                                    message = "Invalid / not found"
                                )
                            ),
                        uploadedCount = 3
                    ),
                coordinatorState = AutoFlushCoordinatorState()
            )

        assertThat(state.serverResultSummary).contains("Confirmed: 1")
        assertThat(state.serverResultSummary).contains("Already processed by server: 1")
        assertThat(state.serverResultSummary).contains("Rejected: 1")
        // No message parsing: we never surface "Invalid / not found" as a structured classification.
        assertThat(state.serverResultSummary).doesNotContain("Invalid")
        assertThat(state.serverResultSummary).doesNotContain("not found")
    }
}
