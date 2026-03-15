package za.co.voelgoed.fastcheck.feature.diagnostics

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import javax.inject.Inject
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
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
    private val diagnosticsUiStateFactory: DiagnosticsUiStateFactory
) : ViewModel() {
    private val _uiState = MutableStateFlow(DiagnosticsUiState())
    val uiState: StateFlow<DiagnosticsUiState> = _uiState.asStateFlow()

    fun refresh() {
        viewModelScope.launch {
            val session = sessionRepository.currentSession()
            val tokenPresent = !sessionProvider.bearerToken().isNullOrBlank()
            val syncStatus = syncRepository.currentSyncStatus()
            val queueDepth = mobileScanRepository.pendingQueueDepth()
            val latestFlushReport = mobileScanRepository.latestFlushReport()

            _uiState.update {
                diagnosticsUiStateFactory.create(
                    session = session,
                    tokenPresent = tokenPresent,
                    syncStatus = syncStatus,
                    queueDepth = queueDepth,
                    latestFlushReport = latestFlushReport
                )
            }
        }
    }
}
