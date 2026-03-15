package za.co.voelgoed.fastcheck.app

import android.os.Bundle
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.ComponentActivity
import androidx.activity.viewModels
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import dagger.hilt.android.AndroidEntryPoint
import javax.inject.Inject
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch
import za.co.voelgoed.fastcheck.R
import za.co.voelgoed.fastcheck.databinding.ActivityMainBinding
import za.co.voelgoed.fastcheck.feature.auth.AuthViewModel
import za.co.voelgoed.fastcheck.feature.diagnostics.DiagnosticsViewModel
import za.co.voelgoed.fastcheck.feature.queue.QueueViewModel
import za.co.voelgoed.fastcheck.feature.scanning.analysis.MlKitBarcodeFrameAnalyzer
import za.co.voelgoed.fastcheck.feature.scanning.camera.ScannerCameraBinder
import za.co.voelgoed.fastcheck.feature.scanning.ui.ScanningViewModel
import za.co.voelgoed.fastcheck.feature.sync.SyncViewModel

@AndroidEntryPoint
class MainActivity : ComponentActivity() {
    private lateinit var binding: ActivityMainBinding

    @Inject
    lateinit var scannerCameraBinder: ScannerCameraBinder

    @Inject
    lateinit var mlKitBarcodeFrameAnalyzer: MlKitBarcodeFrameAnalyzer

    private val authViewModel: AuthViewModel by viewModels()
    private val syncViewModel: SyncViewModel by viewModels()
    private val diagnosticsViewModel: DiagnosticsViewModel by viewModels()
    private val queueViewModel: QueueViewModel by viewModels()
    private val scanningViewModel: ScanningViewModel by viewModels()
    private var scannerBound = false
    private var scannerBindingInProgress = false

    private val cameraPermissionLauncher =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
            scanningViewModel.refreshPermissionState(granted)

            if (granted) {
                bindScannerPreview()
            }
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityMainBinding.inflate(layoutInflater)
        setContentView(binding.root)

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
                    authViewModel.uiState.collectLatest { state ->
                        binding.sessionSummaryValue.text =
                            state.sessionSummary ?: getString(R.string.no_active_session)
                        binding.authErrorValue.text = state.errorMessage ?: getString(R.string.no_errors)
                        binding.loginButton.isEnabled = !state.isSubmitting
                        diagnosticsViewModel.refresh()
                    }
                }

                launch {
                    syncViewModel.uiState.collectLatest { state ->
                        binding.syncSummaryValue.text = state.summaryMessage
                        binding.syncErrorValue.text = state.errorMessage ?: getString(R.string.no_errors)
                        binding.syncButton.isEnabled = !state.isSyncing

                        if (!state.isSyncing) {
                            diagnosticsViewModel.refresh()
                        }
                    }
                }

                launch {
                    diagnosticsViewModel.uiState.collectLatest { state ->
                        binding.currentEventValue.text = state.currentEvent
                        binding.authStateValue.text = state.authSessionState
                        binding.tokenExpiryValue.text = state.tokenExpiryState
                        binding.lastSyncValue.text = state.lastAttendeeSyncTime
                        binding.attendeeCountValue.text = state.attendeeCount
                        binding.queueDepthValue.text = state.queueDepth
                        binding.latestFlushStateValue.text = state.latestFlushState
                        binding.latestFlushSummaryValue.text = state.latestFlushSummary
                        binding.recentOutcomeSummaryValue.text = state.recentOutcomeSummary
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
                        diagnosticsViewModel.refresh()
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

                        if (state.isPreviewVisible && !scannerBound) {
                            bindScannerPreview()
                        }
                    }
                }
            }
        }

        scanningViewModel.refreshPermissionState(hasCameraPermission())
        diagnosticsViewModel.refresh()
    }

    private fun bindScannerPreview() {
        if (!hasCameraPermission() || scannerBound || scannerBindingInProgress) {
            return
        }

        scannerBindingInProgress = true
        scanningViewModel.onScannerBindingStarted()
        scannerCameraBinder.bind(
            lifecycleOwner = this,
            previewView = binding.scannerPreview,
            analyzer = mlKitBarcodeFrameAnalyzer,
            onBound = {
                scannerBindingInProgress = false
                scannerBound = true
                scanningViewModel.onScannerReady()
            },
            onError = { throwable ->
                scannerBindingInProgress = false
                scannerBound = false
                scanningViewModel.onScannerBindingFailed(throwable.message)
            }
        )
    }

    private fun hasCameraPermission(): Boolean =
        ContextCompat.checkSelfPermission(
            this,
            android.Manifest.permission.CAMERA
        ) == android.content.pm.PackageManager.PERMISSION_GRANTED
}
