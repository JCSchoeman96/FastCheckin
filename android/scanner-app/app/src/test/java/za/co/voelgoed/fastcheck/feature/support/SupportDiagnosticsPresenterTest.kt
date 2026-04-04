package za.co.voelgoed.fastcheck.feature.support

import com.google.common.truth.Truth.assertThat
import org.junit.Test
import za.co.voelgoed.fastcheck.feature.diagnostics.DiagnosticsUiState

class SupportDiagnosticsPresenterTest {
    private val presenter = SupportDiagnosticsPresenter()

    @Test
    fun diagnosticsAreGroupedIntoSupportSections() {
        val uiState =
            presenter.present(
                DiagnosticsUiState(
                    currentEvent = "Event A (#1)",
                    authSessionState = "Authenticated",
                    tokenExpiryState = "Valid",
                    apiTargetLabel = "release",
                    apiBaseUrl = "https://scan.voelgoed.co.za/",
                    lastAttendeeSyncTime = "2026-03-13T10:00:00Z",
                    attendeeCount = "42",
                    localQueueDepthLabel = "Queued locally: 2",
                    uploadStateLabel = "Retry pending",
                    serverResultSummary = "Confirmed: 1",
                    latestFlushSummary = "Retry pending"
                )
            )

        assertThat(uiState.sections.map { it.title }).containsExactly(
            "Session and event",
            "Attendee sync",
            "Queue and upload",
            "Environment"
        )
        assertThat(uiState.sections.last().items.map { it.label })
            .containsExactly("API target", "Resolved base URL")
    }
}
