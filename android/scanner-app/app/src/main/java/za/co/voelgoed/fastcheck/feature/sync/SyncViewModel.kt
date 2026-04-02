package za.co.voelgoed.fastcheck.feature.sync

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import java.time.Clock
import javax.inject.Inject
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import za.co.voelgoed.fastcheck.data.repository.SyncRateLimitedException
import za.co.voelgoed.fastcheck.data.repository.SyncRepository

@HiltViewModel
class SyncViewModel @Inject constructor(
    private val syncRepository: SyncRepository,
    private val clock: Clock
) : ViewModel() {
    private val _uiState = MutableStateFlow(SyncScreenUiState())
    val uiState: StateFlow<SyncScreenUiState> = _uiState.asStateFlow()

    fun syncAttendees() {
        val now = clock.millis()
        val current = _uiState.value

        // Single-flight guard: if a sync is already in progress, ignore additional taps.
        // Caveat: this is safe when syncAttendees() is called only from the main/UI path (true today).
        // If it is later invoked from multiple dispatchers or non-UI collectors, a plain state check
        // can race; use a Mutex or atomic compare-and-set style guard for that case.
        if (current.isSyncing) return

        // If we know a concrete nextAllowedSyncAtMillis and haven't reached it yet, treat this
        // tap as noise and just keep the calm rate-limit message.
        if (current.isRateLimited && current.nextAllowedSyncAtMillis?.let { now < it } == true) {
            return
        }

        _uiState.update { it.copy(isSyncing = true, errorMessage = null) }

        viewModelScope.launch {
            runCatching { syncRepository.syncAttendees() }
                .onSuccess { status ->
                    _uiState.update {
                        it.copy(
                            isSyncing = false,
                            summaryMessage =
                                status?.let { sync ->
                                    val syncType =
                                        when (val value = sync.syncType) {
                                            null -> "unknown"
                                            else -> if (value.isBlank()) "unknown" else value
                                        }
                                    "Synced ${sync.attendeeCount} attendees via $syncType sync."
                                } ?: "No active session. Login before syncing.",
                            errorMessage = null,
                            isRateLimited = false,
                            nextAllowedSyncAtMillis = null
                        )
                    }
                }
                .onFailure { throwable ->
                    _uiState.update { state ->
                        when (throwable) {
                            is SyncRateLimitedException ->
                                state.copy(
                                    isSyncing = false,
                                    isRateLimited = true,
                                    nextAllowedSyncAtMillis =
                                        throwable.retryAfterMillis?.let { now + it },
                                    errorMessage = throwable.message
                                )
                            else ->
                                state.copy(
                                    isSyncing = false,
                                    errorMessage = throwable.message ?: "Attendee sync failed."
                                )
                        }
                    }
                }
        }
    }
}
