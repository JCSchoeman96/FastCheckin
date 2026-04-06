package za.co.voelgoed.fastcheck.feature.search

import java.time.Clock
import za.co.voelgoed.fastcheck.core.designsystem.semantic.StatusTone
import za.co.voelgoed.fastcheck.domain.model.AttendeeDetailRecord
import za.co.voelgoed.fastcheck.domain.model.AttendeeSearchRecord
import za.co.voelgoed.fastcheck.domain.model.LocalAdmissionOverlayState
import za.co.voelgoed.fastcheck.domain.model.AttendeeSyncStatus
import za.co.voelgoed.fastcheck.domain.policy.CurrentEventAdmissionReadiness
import za.co.voelgoed.fastcheck.feature.search.detail.AttendeeDetailPresenter
import za.co.voelgoed.fastcheck.feature.search.detail.model.ManualActionUiState
import za.co.voelgoed.fastcheck.feature.search.model.SearchResultRowUiModel
import za.co.voelgoed.fastcheck.feature.search.model.SearchUiState

class SearchDestinationPresenter(
    private val readiness: CurrentEventAdmissionReadiness = CurrentEventAdmissionReadiness(Clock.systemUTC()),
    private val detailPresenter: AttendeeDetailPresenter = AttendeeDetailPresenter()
) {
    fun present(
        eventId: Long,
        query: String,
        results: List<AttendeeSearchRecord>,
        selectedDetail: AttendeeDetailRecord?,
        syncStatus: AttendeeSyncStatus?,
        manualActionUiState: ManualActionUiState
    ): SearchUiState {
        val trustedCache = readiness.hasTrustedCurrentEventCache(eventId, syncStatus)

        return SearchUiState(
            query = query,
            canClear = query.isNotBlank() || selectedDetail != null,
            localTruthMessage =
                if (trustedCache) {
                    "Search uses the local attendee cache and local gate state for this event."
                } else {
                    "The local attendee cache is not trusted enough for green admission decisions yet."
                },
            localTruthTone = if (trustedCache) StatusTone.Info else StatusTone.Warning,
            isShowingDetail = selectedDetail != null,
            results = results.map(::toRow),
            emptyStateMessage =
                when {
                    query.isBlank() ->
                        "Search by ticket code, attendee name, or email. Blank search stays empty."
                    results.isEmpty() ->
                        "No local attendee matches were found for this query."
                    else ->
                        ""
                },
            detailUiState = selectedDetail?.let { detailPresenter.present(it, manualActionUiState) }
        )
    }

    private fun toRow(record: AttendeeSearchRecord): SearchResultRowUiModel {
        val statusText =
            when {
                record.localOverlayState in LocalAdmissionOverlayState.conflictStates.map { it.name } ->
                    "Conflict blocks admission"
                record.isCurrentlyInside ->
                    "Already inside locally"
                record.checkinsRemaining <= 0 ->
                    "No check-ins remaining"
                else ->
                    "Locally admissible"
            }

        val statusTone =
            when {
                record.localOverlayState in LocalAdmissionOverlayState.conflictStates.map { it.name } ->
                    StatusTone.Warning
                record.isCurrentlyInside || record.checkinsRemaining <= 0 ->
                    StatusTone.Warning
                else ->
                    StatusTone.Success
            }

        val supportingText =
            listOfNotNull(
                record.ticketCode,
                record.email,
                record.ticketType
            ).joinToString(" • ")

        return SearchResultRowUiModel(
            attendeeId = record.id,
            displayName = record.displayName,
            supportingText = supportingText,
            statusText = statusText,
            statusTone = statusTone
        )
    }
}
