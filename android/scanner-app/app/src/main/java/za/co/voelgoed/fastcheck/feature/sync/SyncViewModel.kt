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
import za.co.voelgoed.fastcheck.domain.model.AttendeeSyncStatus

@HiltViewModel
class SyncViewModel @Inject constructor(
    private val syncRepository: SyncRepository,
    private val clock: Clock
) : ViewModel() {
    private val _uiState = MutableStateFlow(SyncScreenUiState())
    val uiState: StateFlow<SyncScreenUiState> = _uiState.asStateFlow()

    private val _currentEventSyncStatus = MutableStateFlow<AttendeeSyncStatus?>(null)
    val currentEventSyncStatus: StateFlow<AttendeeSyncStatus?> = _currentEventSyncStatus.asStateFlow()

    private val bootstrapAttemptedEvents = mutableSetOf<Long>()

    fun syncAttendees() {
        performSync(isBootstrap = false, bootstrapEventId = null)
    }

    fun refreshCurrentEventSyncStatus() {
        viewModelScope.launch {
            _currentEventSyncStatus.value = syncRepository.currentSyncStatus()
        }
    }

    fun ensureBootstrapSyncForEvent(eventId: Long) {
        if (_uiState.value.isSyncing) return

        viewModelScope.launch {
            val persistedStatus = syncRepository.currentSyncStatus()
            val currentStatus = persistedStatus ?: _currentEventSyncStatus.value

            if (persistedStatus != null) {
                _currentEventSyncStatus.value = persistedStatus
            }

            if (currentStatus?.eventId == eventId) {
                _uiState.update { current ->
                    current.copy(
                        bootstrapStatus = BootstrapSyncStatus.Succeeded,
                        bootstrapEventId = eventId
                    )
                }
                return@launch
            }

            if (!bootstrapAttemptedEvents.add(eventId)) {
                return@launch
            }

            performSync(isBootstrap = true, bootstrapEventId = eventId)
        }
    }

    fun resetBootstrapState() {
        bootstrapAttemptedEvents.clear()
        _uiState.update { current ->
            current.copy(
                bootstrapStatus = BootstrapSyncStatus.Idle,
                bootstrapEventId = null
            )
        }
    }

    private fun performSync(
        isBootstrap: Boolean,
        bootstrapEventId: Long?
    ) {
        val now = clock.millis()
        val current = _uiState.value

        if (current.isSyncing) return

        if (current.isRateLimited && current.nextAllowedSyncAtMillis?.let { now < it } == true) {
            return
        }

        _uiState.update {
            it.copy(
                isSyncing = true,
                errorMessage = null,
                bootstrapStatus =
                    if (isBootstrap) {
                        BootstrapSyncStatus.Syncing
                    } else {
                        it.bootstrapStatus
                    },
                bootstrapEventId =
                    if (isBootstrap) {
                        bootstrapEventId
                    } else {
                        it.bootstrapEventId
                    }
            )
        }

        viewModelScope.launch {
            runCatching { syncRepository.syncAttendees() }
                .onSuccess { status ->
                    _currentEventSyncStatus.value = status
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
                            nextAllowedSyncAtMillis = null,
                            bootstrapStatus =
                                if (isBootstrap) {
                                    BootstrapSyncStatus.Succeeded
                                } else {
                                    it.bootstrapStatus
                                },
                            bootstrapEventId =
                                if (isBootstrap) {
                                    bootstrapEventId
                                } else {
                                    it.bootstrapEventId
                                }
                        )
                    }
                }
                .onFailure { throwable ->
                    _uiState.update { state ->
                        when (throwable) {
                            is SyncRateLimitedException -> {
                                val rateLimitThrowable: Throwable = throwable
                                state.copy(
                                    isSyncing = false,
                                    isRateLimited = true,
                                    nextAllowedSyncAtMillis =
                                        throwable.retryAfterMillis?.let { now + it },
                                    bootstrapStatus =
                                        if (isBootstrap) {
                                            BootstrapSyncStatus.Failed
                                        } else {
                                            state.bootstrapStatus
                                        },
                                    bootstrapEventId =
                                        if (isBootstrap) {
                                            bootstrapEventId
                                        } else {
                                            state.bootstrapEventId
                                        },
                                    errorMessage =
                                        rateLimitThrowable.message
                                            ?: "Sync is temporarily rate-limited. Please wait a moment before trying again."
                                )
                            }

                            else ->
                                state.copy(
                                    isSyncing = false,
                                    bootstrapStatus =
                                        if (isBootstrap) {
                                            BootstrapSyncStatus.Failed
                                        } else {
                                            state.bootstrapStatus
                                        },
                                    bootstrapEventId =
                                        if (isBootstrap) {
                                            bootstrapEventId
                                        } else {
                                            state.bootstrapEventId
                                        },
                                    errorMessage = throwable.message ?: "Attendee sync failed."
                                )
                        }
                    }
                }
        }
    }
}
