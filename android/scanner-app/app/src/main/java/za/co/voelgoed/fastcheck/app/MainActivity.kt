package za.co.voelgoed.fastcheck.app

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import dagger.hilt.android.AndroidEntryPoint
import java.time.Clock
import javax.inject.Inject
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch
import za.co.voelgoed.fastcheck.R
import za.co.voelgoed.fastcheck.core.autoflush.AutoFlushCoordinator
import za.co.voelgoed.fastcheck.core.autoflush.AutoFlushTrigger
import za.co.voelgoed.fastcheck.core.common.AppDispatchers
import za.co.voelgoed.fastcheck.databinding.ActivityMainBinding
import za.co.voelgoed.fastcheck.feature.scanning.analysis.BarcodeScannerEngine
import za.co.voelgoed.fastcheck.feature.auth.AuthViewModel
import za.co.voelgoed.fastcheck.feature.diagnostics.DiagnosticsViewModel
import za.co.voelgoed.fastcheck.feature.queue.QueueViewModel
import za.co.voelgoed.fastcheck.feature.scanning.camera.ScannerCameraBinder
import za.co.voelgoed.fastcheck.feature.scanning.camera.CameraScannerInputSource
import za.co.voelgoed.fastcheck.feature.scanning.ui.ScanningViewModel
import za.co.voelgoed.fastcheck.feature.scanning.usecase.ScanCapturePipeline
import za.co.voelgoed.fastcheck.feature.scanning.usecase.ScannerSourceBinding
import za.co.voelgoed.fastcheck.feature.sync.SyncViewModel

@AndroidEntryPoint
class MainActivity : ComponentActivity() {
    private lateinit var binding: ActivityMainBinding

    @Inject
    lateinit var scannerCameraBinder: ScannerCameraBinder

    @Inject
    lateinit var appDispatchers: AppDispatchers

    @Inject
    lateinit var clock: Clock

    @Inject
    lateinit var barcodeScannerEngine: BarcodeScannerEngine

    @Inject
    lateinit var scanCapturePipeline: ScanCapturePipeline

    @Inject
    lateinit var autoFlushCoordinator: AutoFlushCoordinator

    private val authViewModel: AuthViewModel by viewModels()
    private val syncViewModel: SyncViewModel by viewModels()
    private val diagnosticsViewModel: DiagnosticsViewModel by viewModels()
    private val queueViewModel: QueueViewModel by viewModels()
    private val scanningViewModel: ScanningViewModel by viewModels()

    private lateinit var scannerInputSource: CameraScannerInputSource
    private lateinit var scannerSourceBinding: ScannerSourceBinding

    private val cameraPermissionLauncher =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
            scanningViewModel.refreshPermissionState(granted)

            if (granted) {
                if (lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED)) {
                    scannerSourceBinding.start()
                }
            }
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityMainBinding.inflate(layoutInflater)
        setContentView(binding.root)

        scannerInputSource =
            CameraScannerInputSource(
                scannerCameraBinder = scannerCameraBinder,
                lifecycleOwnerProvider = { this },
                previewViewProvider = { binding.scannerPreview },
                appDispatchers = appDispatchers,
                clock = clock,
                barcodeScannerEngine = barcodeScannerEngine
            )
        scannerSourceBinding =
            ScannerSourceBinding(
                source = scannerInputSource,
                decodedBarcodeHandler = scanCapturePipeline,
                parentScope = lifecycleScope
            )

        binding.loginButton.setOnClickListener {
            authViewModel.updateEventId(binding.eventIdInput.text.toString())
            authViewModel.updateCredential(binding.credentialInput.text.toString())
            authViewModel.login()
        }

        binding.syncButton.setOnClickListener {
            syncViewModel.syncAttendees()
        }

        binding.requestCameraPermissionButton.setOnClickListener {
            scanningViewModel.onPermissionRequestStarted()
            cameraPermissionLauncher.launch(android.Manifest.permission.CAMERA)
        }

        binding.queueScanButton.setOnClickListener {
            queueViewModel.updateTicketCode(binding.manualTicketCodeInput.text.toString())
            queueViewModel.queueManualScan()
        }

        binding.flushQueueButton.setOnClickListener {
            queueViewModel.flushQueuedScans()
        }

        binding.refreshDiagnosticsButton.setOnClickListener {
            diagnosticsViewModel.refresh()
        }

        lifecycleScope.launch {
            repeatOnLifecycle(Lifecycle.State.STARTED) {
                launch {
                    var lastHadSession = false
                    authViewModel.uiState.collectLatest { state ->
                        binding.sessionSummaryValue.text =
                            state.sessionSummary ?: getString(R.string.no_active_session)
                        binding.authErrorValue.text = state.errorMessage ?: getString(R.string.no_errors)
                        binding.loginButton.isEnabled = !state.isSubmitting

                        val hasSession =
                            state.sessionSummary != null &&
                                state.errorMessage == null &&
                                !state.isSubmitting
                        if (!lastHadSession && hasSession) {
                            diagnosticsViewModel.refresh()
                            autoFlushCoordinator.requestFlush(AutoFlushTrigger.PostLogin)
                        }
                        lastHadSession = hasSession
                    }
                }

                launch {
                    var lastWasSyncing = false
                    var lastError: String? = null
                    syncViewModel.uiState.collectLatest { state ->
                        binding.syncSummaryValue.text = state.summaryMessage
                        binding.syncErrorValue.text = state.errorMessage ?: getString(R.string.no_errors)
                        binding.syncButton.isEnabled = !state.isSyncing

                        val completedNow = lastWasSyncing && !state.isSyncing
                        val succeededNow = completedNow && lastError == null && state.errorMessage == null
                        if (succeededNow) {
                            diagnosticsViewModel.refresh()
                            autoFlushCoordinator.requestFlush(AutoFlushTrigger.PostSync)
                        }

                        lastWasSyncing = state.isSyncing
                        lastError = state.errorMessage
                    }
                }

                launch {
                    diagnosticsViewModel.uiState.collectLatest { state ->
                        binding.currentEventValue.text = state.currentEvent
                        binding.authStateValue.text = state.authSessionState
                        binding.tokenExpiryValue.text = state.tokenExpiryState
                        binding.lastSyncValue.text = state.lastAttendeeSyncTime
                        binding.attendeeCountValue.text = state.attendeeCount
                        binding.queueDepthValue.text = state.localQueueDepthLabel
                        binding.latestFlushStateValue.text = state.uploadStateLabel
                        binding.latestFlushSummaryValue.text = state.latestFlushSummary
                        binding.recentOutcomeSummaryValue.text = state.serverResultSummary
                    }
                }

                launch {
                    queueViewModel.uiState.collectLatest { state ->
                        binding.manualTicketCodeInput.setText(state.ticketCodeInput)
                        binding.manualDirectionValue.text = state.directionLabel
                        binding.scanActionValue.text = state.lastActionMessage
                        binding.scanErrorValue.text =
                            state.validationMessage ?: getString(R.string.no_errors)
                        binding.queueScanButton.isEnabled = !state.isQueueing
                        binding.flushQueueButton.isEnabled = !state.isFlushing
                        binding.manualQueueDepthValue.text = "Queued locally: ${state.localQueueDepth}"
                        binding.manualUploadStateValue.text = state.uploadStateLabel
                    }
                }

                launch {
                    scanningViewModel.uiState.collectLatest { state ->
                        binding.scannerPermissionValue.text = state.permissionSummary
                        binding.scannerStatusValue.text = state.scannerStatus
                        binding.requestCameraPermissionButton.isEnabled = state.isPermissionRequestEnabled
                        binding.scannerPreview.visibility =
                            if (state.isPreviewVisible) {
                                android.view.View.VISIBLE
                            } else {
                                android.view.View.GONE
                            }
                        // Preview visibility now reflects source state; binding to the
                        // camera-backed source is owned by ScannerSourceBinding.
                    }
                }

                launch {
                    scannerSourceBinding.sourceState.collectLatest { state ->
                        scanningViewModel.onSourceStateChanged(state)
                    }
                }

                launch {
                    scanCapturePipeline.handoffResults.collectLatest { result ->
                        scanningViewModel.onCaptureHandoffResult(result)
                        if (result is za.co.voelgoed.fastcheck.feature.scanning.usecase.CaptureHandoffResult.Accepted) {
                            autoFlushCoordinator.requestFlush(AutoFlushTrigger.AfterEnqueue)
                        }
                    }
                }
            }
        }

        scanningViewModel.refreshPermissionState(hasCameraPermission())
        diagnosticsViewModel.refresh()
    }

    override fun onStart() {
        super.onStart()
        autoFlushCoordinator.requestFlush(AutoFlushTrigger.ForegroundResume)
        if (hasCameraPermission()) {
            scannerSourceBinding.start()
        }
    }

    override fun onStop() {
        scannerSourceBinding.stop()
        super.onStop()
    }

    private fun hasCameraPermission(): Boolean =
        ContextCompat.checkSelfPermission(
            this,
            android.Manifest.permission.CAMERA
        ) == android.content.pm.PackageManager.PERMISSION_GRANTED
}
