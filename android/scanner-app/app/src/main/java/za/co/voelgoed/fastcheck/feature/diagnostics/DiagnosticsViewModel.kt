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
import za.co.voelgoed.fastcheck.core.autoflush.AutoFlushCoordinatorState
import za.co.voelgoed.fastcheck.core.connectivity.ConnectivityMonitor
import za.co.voelgoed.fastcheck.core.designsystem.semantic.SyncUiState
import za.co.voelgoed.fastcheck.core.designsystem.semantic.toSyncUiState
import za.co.voelgoed.fastcheck.core.network.ApiEnvironmentConfig
import za.co.voelgoed.fastcheck.core.network.SessionProvider
import za.co.voelgoed.fastcheck.data.repository.MobileScanRepository
import za.co.voelgoed.fastcheck.data.repository.SessionRepository
import za.co.voelgoed.fastcheck.data.repository.SyncRepository
import za.co.voelgoed.fastcheck.domain.model.AttendeeSyncStatus
import za.co.voelgoed.fastcheck.domain.model.FlushReport

@HiltViewModel
class DiagnosticsViewModel @Inject constructor(
    private val apiEnvironmentConfig: ApiEnvironmentConfig,
    private val sessionRepository: SessionRepository,
    private val sessionProvider: SessionProvider,
    private val syncRepository: SyncRepository,
    private val mobileScanRepository: MobileScanRepository,
    private val autoFlushCoordinator: AutoFlushCoordinator,
    private val connectivityMonitor: ConnectivityMonitor,
    private val diagnosticsUiStateFactory: DiagnosticsUiStateFactory
) : ViewModel() {
    private val _uiState = MutableStateFlow(DiagnosticsUiState())
    val uiState: StateFlow<DiagnosticsUiState> = _uiState.asStateFlow()

    private val sessionInput = MutableStateFlow<SessionInputs>(SessionInputs())

    init {
        viewModelScope.launch {
            combine(
                sessionInput,
                syncRepository.observeLastSyncedStatus(),
                mobileScanRepository.observePendingQueueDepth(),
                mobileScanRepository.observeLatestFlushReport(),
                autoFlushCoordinator.state
            ) { inputs, lastSyncedStatus, queueDepth, latestFlushReport, coordinatorState ->
                DiagnosticsProjection(
                    inputs = inputs,
                    lastSyncedStatus = lastSyncedStatus,
                    queueDepth = queueDepth,
                    latestFlushReport = latestFlushReport,
                    coordinatorState = coordinatorState
                )
            }.combine(connectivityMonitor.isOnline) { projection, isOnline ->
                val syncUiState =
                    projection.coordinatorState.toSyncUiState(
                        isOnline = isOnline,
                        latestFlushReport = projection.latestFlushReport,
                        pendingQueueDepth = projection.queueDepth
                    )
                DiagnosticsInputs(
                    inputs = projection.inputs,
                    lastSyncedStatus = projection.lastSyncedStatus,
                    queueDepth = projection.queueDepth,
                    latestFlushReport = projection.latestFlushReport,
                    syncUiState = syncUiState
                )
            }.collect { diagnosticsInputs ->
                _uiState.update {
                    diagnosticsUiStateFactory.create(
                        apiEnvironmentConfig = apiEnvironmentConfig,
                        session = diagnosticsInputs.inputs.session,
                        tokenPresent = diagnosticsInputs.inputs.tokenPresent,
                        syncStatus = diagnosticsInputs.lastSyncedStatus,
                        queueDepth = diagnosticsInputs.queueDepth,
                        latestFlushReport = diagnosticsInputs.latestFlushReport,
                        syncUiState = diagnosticsInputs.syncUiState
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
        sessionInput.value =
            SessionInputs(
                session = session,
                    tokenPresent = tokenPresent
                )
        }
    }

    private data class SessionInputs(
        val session: za.co.voelgoed.fastcheck.domain.model.ScannerSession? = null,
        val tokenPresent: Boolean = false
    )

    private data class DiagnosticsInputs(
        val inputs: SessionInputs,
        val lastSyncedStatus: za.co.voelgoed.fastcheck.domain.model.AttendeeSyncStatus?,
        val queueDepth: Int,
        val latestFlushReport: za.co.voelgoed.fastcheck.domain.model.FlushReport?,
        val syncUiState: SyncUiState
    )

    private data class DiagnosticsProjection(
        val inputs: SessionInputs,
        val lastSyncedStatus: AttendeeSyncStatus?,
        val queueDepth: Int,
        val latestFlushReport: FlushReport?,
        val coordinatorState: AutoFlushCoordinatorState
    )
}
