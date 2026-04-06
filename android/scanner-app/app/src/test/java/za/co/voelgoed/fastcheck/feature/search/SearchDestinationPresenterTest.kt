package za.co.voelgoed.fastcheck.feature.search

import com.google.common.truth.Truth.assertThat
import java.time.Clock
import java.time.Instant
import java.time.ZoneOffset
import org.junit.Test
import za.co.voelgoed.fastcheck.core.designsystem.semantic.StatusTone
import za.co.voelgoed.fastcheck.domain.model.AttendeeSyncStatus
import za.co.voelgoed.fastcheck.domain.policy.CurrentEventAdmissionReadiness
import za.co.voelgoed.fastcheck.feature.search.detail.AttendeeDetailPresenter
import za.co.voelgoed.fastcheck.feature.search.detail.model.ManualActionUiState

class SearchDestinationPresenterTest {
    private val clock = Clock.fixed(Instant.parse("2026-04-06T10:00:00Z"), ZoneOffset.UTC)
    private val readiness = CurrentEventAdmissionReadiness(clock)
    private val presenter = SearchDestinationPresenter(readiness = readiness, detailPresenter = AttendeeDetailPresenter())

    @Test
    fun trustedCacheShowsSearchUsesLocalAttendeeCacheMessage() {
        val trusted =
            AttendeeSyncStatus(
                eventId = 42L,
                lastServerTime = "2026-04-06T09:55:00Z",
                lastSuccessfulSyncAt = "2026-04-06T09:55:00Z",
                syncType = "full",
                attendeeCount = 10
            )

        val state =
            presenter.present(
                eventId = 42L,
                query = "jane",
                results = emptyList(),
                selectedDetail = null,
                syncStatus = trusted,
                manualActionUiState = ManualActionUiState()
            )

        assertThat(state.localTruthMessage).contains("local attendee cache")
        assertThat(state.localTruthTone).isEqualTo(StatusTone.Info)
    }

    @Test
    fun untrustedCacheShowsWarningTruthMessage() {
        val state =
            presenter.present(
                eventId = 42L,
                query = "jane",
                results = emptyList(),
                selectedDetail = null,
                syncStatus = null,
                manualActionUiState = ManualActionUiState()
            )

        assertThat(state.localTruthMessage).contains("not trusted")
        assertThat(state.localTruthTone).isEqualTo(StatusTone.Warning)
    }
}
