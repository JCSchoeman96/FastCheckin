package za.co.voelgoed.fastcheck.app

import android.os.Bundle
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.ComponentActivity
import androidx.activity.viewModels
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
import za.co.voelgoed.fastcheck.feature.scanning.camera.ScannerCameraBinder
import za.co.voelgoed.fastcheck.feature.scanning.ui.ScannerScreen
import za.co.voelgoed.fastcheck.feature.scanning.ui.ScanningViewModel
import za.co.voelgoed.fastcheck.feature.sync.SyncViewModel

@AndroidEntryPoint
class MainActivity : ComponentActivity() {
    private lateinit var binding: ActivityMainBinding

    @Inject
    lateinit var scannerCameraBinder: ScannerCameraBinder

    private val authViewModel: AuthViewModel by viewModels()
    private val syncViewModel: SyncViewModel by viewModels()
    private val diagnosticsViewModel: DiagnosticsViewModel by viewModels()
    private val queueViewModel: QueueViewModel by viewModels()
    private val scanningViewModel: ScanningViewModel by viewModels()
    private lateinit var scannerScreen: ScannerScreen

    private val cameraPermissionLauncher =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
            scannerScreen.onPermissionResult(granted)
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityMainBinding.inflate(layoutInflater)
        setContentView(binding.root)
        scannerScreen =
            ScannerScreen(
                binding = binding.scannerScreen,
                lifecycleOwner = this,
                scanningViewModel = scanningViewModel,
                scannerCameraBinder = scannerCameraBinder,
                onLaunchPermissionRequest = {
                    cameraPermissionLauncher.launch(android.Manifest.permission.CAMERA)
                }
            )

        binding.loginButton.setOnClickListener {
            authViewModel.updateEventId(binding.eventIdInput.text.toString())
            authViewModel.updateCredential(binding.credentialInput.text.toString())
            authViewModel.login()
        }

        binding.syncButton.setOnClickListener {
            syncViewModel.syncAttendees()
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

        observeUi()
        scannerScreen.start()
        diagnosticsViewModel.refresh()
    }

    private fun observeUi() {
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
            }
        }
    }
}
