package za.co.voelgoed.fastcheck.feature.queue

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import javax.inject.Inject
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import za.co.voelgoed.fastcheck.core.autoflush.AutoFlushCoordinator
import za.co.voelgoed.fastcheck.core.autoflush.AutoFlushCoordinatorState
import za.co.voelgoed.fastcheck.core.autoflush.AutoFlushTrigger
import za.co.voelgoed.fastcheck.core.connectivity.ConnectivityMonitor
import za.co.voelgoed.fastcheck.core.designsystem.semantic.SyncUiState
import za.co.voelgoed.fastcheck.core.designsystem.semantic.toSyncUiState
import za.co.voelgoed.fastcheck.data.repository.MobileScanRepository
import za.co.voelgoed.fastcheck.domain.model.FlushReport
import za.co.voelgoed.fastcheck.domain.model.QueueCreationResult
import za.co.voelgoed.fastcheck.domain.model.QuarantineSummary
import za.co.voelgoed.fastcheck.domain.model.ScanDirection
import za.co.voelgoed.fastcheck.domain.usecase.QueueCapturedScanUseCase

@HiltViewModel
class QueueViewModel @Inject constructor(
    private val queueCapturedScanUseCase: QueueCapturedScanUseCase,
    private val autoFlushCoordinator: AutoFlushCoordinator,
    private val connectivityMonitor: ConnectivityMonitor,
    private val mobileScanRepository: MobileScanRepository,
    private val queueUiStateFactory: QueueUiStateFactory
) : ViewModel() {
    private val _uiState = MutableStateFlow(QueueUiState())
    val uiState: StateFlow<QueueUiState> = _uiState.asStateFlow()

    init {
        viewModelScope.launch {
            combine(
                combine(
                    autoFlushCoordinator.state,
                    mobileScanRepository.observePendingQueueDepth(),
                    mobileScanRepository.observeLatestFlushReport(),
                    connectivityMonitor.isOnline
                ) { coordinatorState, queueDepth, latestFlushReport, isOnline ->
                    QueueCoreObservation(
                        coordinatorState = coordinatorState,
                        queueDepth = queueDepth,
                        latestFlushReport = latestFlushReport,
                        isOnline = isOnline
                    )
                },
                mobileScanRepository.observeQuarantineCount(),
                mobileScanRepository.observeLatestQuarantineSummary()
            ) { core, quarantineCount, quarantineSummary ->
                val syncUiState =
                    core.coordinatorState.toSyncUiState(
                        isOnline = core.isOnline,
                        latestFlushReport = core.latestFlushReport,
                        pendingQueueDepth = core.queueDepth
                    )
                QueueObservation(
                    syncUiState = syncUiState,
                    queueDepth = core.queueDepth,
                    latestFlushReport = core.latestFlushReport,
                    quarantineCount = quarantineCount,
                    quarantineSummary = quarantineSummary
                )
            }.collectLatest { observation ->
                _uiState.update { current ->
                    current.copy(
                        isFlushing = observation.syncUiState is SyncUiState.Syncing,
                        localQueueDepth = observation.queueDepth,
                        uploadSemanticState = observation.syncUiState,
                        uploadStateLabel = observation.syncUiState.defaultLabel,
                        latestFlushSummary =
                            observation.latestFlushReport?.summaryMessage ?: "No flush has run yet.",
                        serverResultHint =
                            queueUiStateFactory.serverResultHintForFlushReport(observation.latestFlushReport),
                        quarantineCount = observation.quarantineCount,
                        quarantineLatestReasonLabel =
                            quarantineReasonLabel(
                                observation.quarantineCount,
                                observation.quarantineSummary
                            )
                    )
                }
            }
        }
    }

    fun updateTicketCode(value: String) {
        _uiState.update { state ->
            state.copy(ticketCodeInput = value, validationMessage = null)
        }
    }

    fun queueManualScan() {
        viewModelScope.launch {
            _uiState.update { it.copy(isQueueing = true, validationMessage = null) }

            val result =
                queueCapturedScanUseCase.enqueue(
                    ticketCode = _uiState.value.ticketCodeInput,
                    direction = ScanDirection.IN,
                    operatorName = MANUAL_OPERATOR_NAME,
                    entranceName = MANUAL_ENTRANCE_NAME
                )

            _uiState.update { state ->
                state.copy(
                    ticketCodeInput =
                        if (result is QueueCreationResult.Enqueued) {
                            ""
                        } else {
                            state.ticketCodeInput
                        },
                    lastActionMessage = queueUiStateFactory.actionMessageForQueueResult(result),
                    validationMessage =
                        when (result) {
                            QueueCreationResult.InvalidTicketCode ->
                                queueUiStateFactory.actionMessageForQueueResult(result)

                            QueueCreationResult.MissingSessionContext ->
                                queueUiStateFactory.actionMessageForQueueResult(result)

                            else -> null
                        },
                    isQueueing = false
                )
            }

            if (result is QueueCreationResult.Enqueued) {
                autoFlushCoordinator.requestFlush(AutoFlushTrigger.AfterEnqueue)
            }
        }
    }

    fun flushQueuedScans() {
        viewModelScope.launch {
            autoFlushCoordinator.requestFlush(AutoFlushTrigger.Manual)
        }
    }

    private fun quarantineReasonLabel(
        count: Int,
        summary: QuarantineSummary?
    ): String? =
        if (count <= 0) {
            null
        } else {
            summary?.latestReason?.wireValue ?: "UNKNOWN"
        }

    private data class QueueCoreObservation(
        val coordinatorState: AutoFlushCoordinatorState,
        val queueDepth: Int,
        val latestFlushReport: FlushReport?,
        val isOnline: Boolean
    )

    private data class QueueObservation(
        val syncUiState: SyncUiState,
        val queueDepth: Int,
        val latestFlushReport: FlushReport?,
        val quarantineCount: Int,
        val quarantineSummary: QuarantineSummary?
    )

    private companion object {
        const val MANUAL_OPERATOR_NAME = "Manual Debug"
        const val MANUAL_ENTRANCE_NAME = "Manual Debug"
    }
}
