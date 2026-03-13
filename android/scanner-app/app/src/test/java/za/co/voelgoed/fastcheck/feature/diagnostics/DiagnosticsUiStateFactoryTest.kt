package za.co.voelgoed.fastcheck.feature.diagnostics

import com.google.common.truth.Truth.assertThat
import java.time.Clock
import java.time.Instant
import java.time.ZoneOffset
import org.junit.Test
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
                latestFlushReport = null
            )

        assertThat(state.currentEvent).isEqualTo("No active event")
        assertThat(state.authSessionState).isEqualTo("Logged out")
        assertThat(state.tokenExpiryState).isEqualTo("Missing")
        assertThat(state.lastAttendeeSyncTime).isEqualTo("Never")
        assertThat(state.latestFlushState).isEqualTo("Never")
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
                    )
            )

        assertThat(state.currentEvent).isEqualTo("Voelgoed Live (#5)")
        assertThat(state.authSessionState).isEqualTo("Authenticated")
        assertThat(state.tokenExpiryState).isEqualTo("Valid")
        assertThat(state.attendeeCount).isEqualTo("42")
        assertThat(state.queueDepth).isEqualTo("3")
        assertThat(state.latestFlushState).isEqualTo("Re-login required")
        assertThat(state.recentOutcomeSummary).contains("VG-100")
    }
}
