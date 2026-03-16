package za.co.voelgoed.fastcheck.feature.queue

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import javax.inject.Inject
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import za.co.voelgoed.fastcheck.domain.model.QueueCreationResult
import za.co.voelgoed.fastcheck.domain.model.ScanDirection
import za.co.voelgoed.fastcheck.domain.usecase.FlushQueuedScansUseCase
import za.co.voelgoed.fastcheck.domain.usecase.QueueCapturedScanUseCase

@HiltViewModel
class QueueViewModel @Inject constructor(
    private val queueCapturedScanUseCase: QueueCapturedScanUseCase,
    private val flushQueuedScansUseCase: FlushQueuedScansUseCase,
    private val queueUiStateFactory: QueueUiStateFactory
) : ViewModel() {
    private val _uiState = MutableStateFlow(QueueUiState())
    val uiState: StateFlow<QueueUiState> = _uiState.asStateFlow()

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
        }
    }

    fun flushQueuedScans() {
        viewModelScope.launch {
            _uiState.update { it.copy(isFlushing = true, validationMessage = null) }
            val report = flushQueuedScansUseCase.run(maxBatchSize = 50)

            _uiState.update { state ->
                state.copy(
                    isFlushing = false,
                    lastActionMessage = queueUiStateFactory.actionMessageForFlushReport(report),
                    validationMessage =
                        if (report.authExpired) {
                            "Manual login required before queued scans can flush."
                        } else {
                            null
                        }
                )
            }
        }
    }

    private companion object {
        const val MANUAL_OPERATOR_NAME = "Manual Debug"
        const val MANUAL_ENTRANCE_NAME = "Manual Debug"
    }
}
