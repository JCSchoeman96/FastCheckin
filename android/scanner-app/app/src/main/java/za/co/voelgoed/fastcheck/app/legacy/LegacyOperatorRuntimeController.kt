package za.co.voelgoed.fastcheck.app.legacy

import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.ui.Modifier
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch
import za.co.voelgoed.fastcheck.R
import za.co.voelgoed.fastcheck.feature.diagnostics.DiagnosticsViewModel
import za.co.voelgoed.fastcheck.feature.queue.ManualQueueInputController
import za.co.voelgoed.fastcheck.feature.queue.QueueViewModel
import za.co.voelgoed.fastcheck.feature.scanning.ui.ScanningViewModel
import za.co.voelgoed.fastcheck.feature.sync.SyncViewModel

class LegacyOperatorRuntimeController(
    private val lifecycleOwner: LifecycleOwner,
    private val syncViewModel: SyncViewModel,
    private val diagnosticsViewModel: DiagnosticsViewModel,
    private val queueViewModel: QueueViewModel,
    private val scanningViewModel: ScanningViewModel,
    private val onRequestCameraPermission: () -> Unit,
    private val onRefreshDiagnostics: () -> Unit,
    private val onViewAttached: () -> Unit,
    private val onViewDetached: () -> Unit
) {
    private var attachedView: LegacyOperatorRuntimeView? = null
    private var manualQueueInputController: ManualQueueInputController? = null
    private var renderJob: Job? = null

    fun attach(view: LegacyOperatorRuntimeView) {
        if (attachedView === view && renderJob != null) {
            return
        }

        detach()
        attachedView = view
        manualQueueInputController =
            ManualQueueInputController(
                input = view.binding.manualTicketCodeInput,
                onTicketCodeChanged = queueViewModel::updateTicketCode
            ).also { controller ->
                controller.bind()
            }

        bindListeners(view)
        renderJob =
            lifecycleOwner.lifecycleScope.launch {
                lifecycleOwner.repeatOnLifecycle(Lifecycle.State.STARTED) {
                    launch {
                        syncViewModel.uiState.collectLatest { state ->
                            val runtimeView = currentView() ?: return@collectLatest
                            runtimeView.binding.syncSummaryValue.text = state.summaryMessage
                            runtimeView.binding.syncErrorValue.text =
                                state.errorMessage
                                    ?: runtimeView.context.getString(R.string.no_errors)
                            runtimeView.binding.syncButton.isEnabled = !state.isSyncing
                        }
                    }

                    launch {
                        diagnosticsViewModel.uiState.collectLatest { state ->
                            val runtimeView = currentView() ?: return@collectLatest
                            runtimeView.binding.currentEventValue.text = state.currentEvent
                            runtimeView.binding.authStateValue.text = state.authSessionState
                            runtimeView.binding.tokenExpiryValue.text = state.tokenExpiryState
                            runtimeView.binding.lastSyncValue.text = state.lastAttendeeSyncTime
                            runtimeView.binding.attendeeCountValue.text = state.attendeeCount
                            runtimeView.binding.queueDepthValue.text = state.localQueueDepthLabel
                            runtimeView.binding.latestFlushStateValue.text = state.uploadStateLabel
                            runtimeView.binding.latestFlushSummaryValue.text = state.latestFlushSummary
                            runtimeView.binding.recentOutcomeSummaryValue.text =
                                state.serverResultSummary
                        }
                    }

                    launch {
                        queueViewModel.uiState.collectLatest { state ->
                            val runtimeView = currentView() ?: return@collectLatest
                            manualQueueInputController?.render(state.ticketCodeInput)
                            runtimeView.binding.manualDirectionValue.text = state.directionLabel
                            runtimeView.binding.scanActionValue.text = state.lastActionMessage
                            runtimeView.binding.scanErrorValue.text =
                                state.validationMessage
                                    ?: runtimeView.context.getString(R.string.no_errors)
                            runtimeView.binding.queueScanButton.isEnabled = !state.isQueueing
                            runtimeView.binding.flushQueueButton.isEnabled = !state.isFlushing
                            runtimeView.binding.manualQueueDepthValue.text =
                                "Queued locally: ${state.localQueueDepth}"
                            runtimeView.binding.manualUploadStateValue.text = state.uploadStateLabel
                            runtimeView.binding.manualServerResultHintValue.text =
                                state.serverResultHint
                        }
                    }

                    launch {
                        scanningViewModel.uiState.collectLatest { state ->
                            val runtimeView = currentView() ?: return@collectLatest
                            runtimeView.binding.scannerPermissionValue.text = state.permissionSummary
                            runtimeView.binding.scannerStatusValue.text = state.scannerStatus
                            runtimeView.binding.requestCameraPermissionButton.isEnabled =
                                state.isPermissionRequestEnabled
                            runtimeView.binding.requestCameraPermissionButton.visibility =
                                if (state.isPermissionRequestVisible) {
                                    android.view.View.VISIBLE
                                } else {
                                    android.view.View.GONE
                                }
                            runtimeView.binding.scannerPreview.visibility =
                                if (state.isPreviewVisible) {
                                    android.view.View.VISIBLE
                                } else {
                                    android.view.View.GONE
                                }
                        }
                    }
                }
            }

        onViewAttached()
    }

    fun detach() {
        if (attachedView != null) {
            onViewDetached()
        }
        renderJob?.cancel()
        renderJob = null
        manualQueueInputController = null
        attachedView = null
    }

    fun requirePreviewView() =
        checkNotNull(attachedView?.previewView) {
            "Legacy scan preview is not attached. The scanner should only bind while the Scan surface is active."
        }

    private fun bindListeners(view: LegacyOperatorRuntimeView) {
        view.binding.syncButton.setOnClickListener {
            syncViewModel.syncAttendees()
        }
        view.binding.requestCameraPermissionButton.setOnClickListener {
            scanningViewModel.onPermissionRequestStarted()
            onRequestCameraPermission()
        }
        view.binding.queueScanButton.setOnClickListener {
            manualQueueInputController?.submitCurrentValue(queueViewModel::updateTicketCode)
            queueViewModel.queueManualScan()
        }
        view.binding.flushQueueButton.setOnClickListener {
            queueViewModel.flushQueuedScans()
        }
        view.binding.refreshDiagnosticsButton.setOnClickListener {
            onRefreshDiagnostics()
        }
    }

    private fun currentView(): LegacyOperatorRuntimeView? = attachedView
}

@Composable
fun LegacyOperatorRuntimeHost(
    controller: LegacyOperatorRuntimeController,
    modifier: Modifier = Modifier
) {
    DisposableEffect(controller) {
        onDispose {
            controller.detach()
        }
    }

    AndroidView(
        modifier = modifier,
        factory = { context ->
            LegacyOperatorRuntimeView(context).also(controller::attach)
        },
        update = controller::attach
    )
}
