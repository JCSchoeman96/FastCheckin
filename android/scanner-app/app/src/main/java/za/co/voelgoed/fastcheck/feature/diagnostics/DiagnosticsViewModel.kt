package za.co.voelgoed.fastcheck.feature.diagnostics

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import javax.inject.Inject
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import za.co.voelgoed.fastcheck.core.autoflush.AutoFlushCoordinator
import za.co.voelgoed.fastcheck.core.network.SessionProvider
import za.co.voelgoed.fastcheck.data.repository.MobileScanRepository
import za.co.voelgoed.fastcheck.data.repository.SessionRepository
import za.co.voelgoed.fastcheck.data.repository.SyncRepository

@HiltViewModel
class DiagnosticsViewModel @Inject constructor(
    private val sessionRepository: SessionRepository,
    private val sessionProvider: SessionProvider,
    private val syncRepository: SyncRepository,
    private val mobileScanRepository: MobileScanRepository,
    private val autoFlushCoordinator: AutoFlushCoordinator,
    private val diagnosticsUiStateFactory: DiagnosticsUiStateFactory
) : ViewModel() {
    private val _uiState = MutableStateFlow(DiagnosticsUiState())
    val uiState: StateFlow<DiagnosticsUiState> = _uiState.asStateFlow()

    private val sessionInput = MutableStateFlow<SessionInputs>(SessionInputs())

    init {
        viewModelScope.launch {
            combine(
                sessionInput,
                mobileScanRepository.observePendingQueueDepth(),
                mobileScanRepository.observeLatestFlushReport(),
                autoFlushCoordinator.state
            ) { inputs, queueDepth, latestFlushReport, coordinatorState ->
                Quad(inputs, queueDepth, latestFlushReport, coordinatorState)
            }.collect { quad ->
                val (inputs, queueDepth, latestFlushReport, coordinatorState) = quad
                _uiState.update {
                    diagnosticsUiStateFactory.create(
                        session = inputs.session,
                        tokenPresent = inputs.tokenPresent,
                        syncStatus = inputs.syncStatus,
                        queueDepth = queueDepth,
                        latestFlushReport = latestFlushReport,
                        coordinatorState = coordinatorState
                    )
                }
            }
        }
    }

    fun refresh() {
        viewModelScope.launch {
            // Guardrail: refresh() updates only ephemeral context (session/token/sync inputs).
            // Durable operational truth (queue depth, persisted flush outcomes) must remain
            // repository/Room-observed to avoid reintroducing UI drift.
            val session = sessionRepository.currentSession()
            val tokenPresent = !sessionProvider.bearerToken().isNullOrBlank()
            val syncStatus = syncRepository.currentSyncStatus()
            sessionInput.value =
                SessionInputs(
                    session = session,
                    tokenPresent = tokenPresent,
                    syncStatus = syncStatus
                )
        }
    }

    private data class SessionInputs(
        val session: za.co.voelgoed.fastcheck.domain.model.ScannerSession? = null,
        val tokenPresent: Boolean = false,
        val syncStatus: za.co.voelgoed.fastcheck.domain.model.AttendeeSyncStatus? = null
    )

    private data class Quad<A, B, C, D>(
        val first: A,
        val second: B,
        val third: C,
        val fourth: D
    )
}
