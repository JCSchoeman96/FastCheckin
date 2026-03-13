package za.co.voelgoed.fastcheck.feature.sync

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import javax.inject.Inject
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import za.co.voelgoed.fastcheck.data.repository.SyncRepository

@HiltViewModel
class SyncViewModel @Inject constructor(
    private val syncRepository: SyncRepository
) : ViewModel() {
    private val _uiState = MutableStateFlow(SyncUiState())
    val uiState: StateFlow<SyncUiState> = _uiState.asStateFlow()

    fun syncAttendees() {
        viewModelScope.launch {
            _uiState.update { it.copy(isSyncing = true, errorMessage = null) }

            runCatching { syncRepository.syncAttendees() }
                .onSuccess { status ->
                    _uiState.update {
                        it.copy(
                            isSyncing = false,
                            summaryMessage =
                                status?.let { sync ->
                                    "Synced ${sync.attendeeCount} attendees via ${sync.syncType ?: "unknown"} sync."
                                } ?: "No active session. Login before syncing.",
                            errorMessage = null
                        )
                    }
                }
                .onFailure { throwable ->
                    _uiState.update {
                        it.copy(
                            isSyncing = false,
                            errorMessage = throwable.message ?: "Attendee sync failed."
                        )
                    }
                }
        }
    }
}
