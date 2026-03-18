package za.co.voelgoed.fastcheck.feature.queue

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import javax.inject.Inject
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import za.co.voelgoed.fastcheck.core.autoflush.AutoFlushCoordinator
import za.co.voelgoed.fastcheck.core.autoflush.AutoFlushTrigger
import za.co.voelgoed.fastcheck.domain.model.QueueCreationResult
import za.co.voelgoed.fastcheck.domain.model.ScanDirection
import za.co.voelgoed.fastcheck.domain.usecase.FlushQueuedScansUseCase
import za.co.voelgoed.fastcheck.domain.usecase.QueueCapturedScanUseCase

@HiltViewModel
class QueueViewModel @Inject constructor(
    private val queueCapturedScanUseCase: QueueCapturedScanUseCase,
    private val flushQueuedScansUseCase: FlushQueuedScansUseCase,
    private val autoFlushCoordinator: AutoFlushCoordinator,
    private val queueUiStateFactory: QueueUiStateFactory
) : ViewModel() {
    private val _uiState = MutableStateFlow(QueueUiState())
    val uiState: StateFlow<QueueUiState> = _uiState.asStateFlow()

    init {
        viewModelScope.launch {
            autoFlushCoordinator.state.collectLatest { coordinatorState ->
                _uiState.update { current ->
                    current.copy(isFlushing = coordinatorState.isFlushing)
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

    private companion object {
        const val MANUAL_OPERATOR_NAME = "Manual Debug"
        const val MANUAL_ENTRANCE_NAME = "Manual Debug"
    }
}
