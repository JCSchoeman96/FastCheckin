package za.co.voelgoed.fastcheck.app

import android.os.Bundle
import android.util.Log
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
import za.co.voelgoed.fastcheck.app.scanning.ScannerShellSourceMode
import za.co.voelgoed.fastcheck.app.scanning.ScannerSourceActivationPolicy
import za.co.voelgoed.fastcheck.app.scanning.ScannerSourceSelectionResolver
import za.co.voelgoed.fastcheck.app.session.AppSessionRoute
import za.co.voelgoed.fastcheck.app.session.SessionGateViewModel
import za.co.voelgoed.fastcheck.core.autoflush.AutoFlushCoordinator
import za.co.voelgoed.fastcheck.core.autoflush.AutoFlushTrigger
import za.co.voelgoed.fastcheck.core.common.AppDispatchers
import za.co.voelgoed.fastcheck.core.network.ApiEnvironmentConfig
import za.co.voelgoed.fastcheck.databinding.ActivityMainBinding
import za.co.voelgoed.fastcheck.feature.scanning.analysis.BarcodeScannerEngine
import za.co.voelgoed.fastcheck.feature.auth.AuthViewModel
import za.co.voelgoed.fastcheck.feature.diagnostics.DiagnosticsViewModel
import za.co.voelgoed.fastcheck.feature.queue.ManualQueueInputController
import za.co.voelgoed.fastcheck.feature.queue.QueueViewModel
import za.co.voelgoed.fastcheck.feature.scanning.broadcast.DataWedgeScannerInputSource
import za.co.voelgoed.fastcheck.feature.scanning.camera.ScannerCameraBinder
import za.co.voelgoed.fastcheck.feature.scanning.camera.CameraScannerInputSource
import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerInputSource
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

    @Inject
    lateinit var apiEnvironmentConfig: ApiEnvironmentConfig

    private val authViewModel: AuthViewModel by viewModels()
    private val sessionGateViewModel: SessionGateViewModel by viewModels()
    private val syncViewModel: SyncViewModel by viewModels()
    private val diagnosticsViewModel: DiagnosticsViewModel by viewModels()
    private val queueViewModel: QueueViewModel by viewModels()
    private val scanningViewModel: ScanningViewModel by viewModels()

    private val scannerSourceSelectionResolver = ScannerSourceSelectionResolver()
    private val scannerSourceActivationPolicy = ScannerSourceActivationPolicy()

    private lateinit var selectedScannerSourceMode: ScannerShellSourceMode
    private lateinit var scannerInputSource: ScannerInputSource
    private lateinit var scannerSourceBinding: ScannerSourceBinding
    private lateinit var manualQueueInputController: ManualQueueInputController
    private var isAuthenticatedRouteActive: Boolean = false

    private val cameraPermissionLauncher =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
            scanningViewModel.refreshPermissionState(granted)
            syncScannerBindingForPermission()
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityMainBinding.inflate(layoutInflater)
        setContentView(binding.root)
        Log.i(
            LOG_TAG,
            "FastCheck API target=${apiEnvironmentConfig.target.wireName} baseUrl=${apiEnvironmentConfig.baseUrl}"
        )
        selectedScannerSourceMode = scannerSourceSelectionResolver.resolve()
        Log.i(LOG_TAG, "Active scanner source=${selectedScannerSourceMode.wireName}")
        scanningViewModel.onActiveSourceTypeChanged(selectedScannerSourceMode.sourceType)
        manualQueueInputController =
            ManualQueueInputController(
                input = binding.manualTicketCodeInput,
                onTicketCodeChanged = queueViewModel::updateTicketCode
            )
        manualQueueInputController.bind()

        scannerInputSource = createScannerInputSource(selectedScannerSourceMode)
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
            manualQueueInputController.submitCurrentValue(queueViewModel::updateTicketCode)
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

                        val authenticatedSession = state.authenticatedSession
                        if (authenticatedSession != null && state.errorMessage == null && !state.isSubmitting) {
                            sessionGateViewModel.onLoginSucceeded(authenticatedSession)
                        }
                    }
                }

                launch {
                    sessionGateViewModel.route.collectLatest { route ->
                        when (route) {
                            AppSessionRoute.RestoringSession,
                            AppSessionRoute.LoggedOut -> {
                                val wasAuthenticated = isAuthenticatedRouteActive
                                isAuthenticatedRouteActive = false
                                binding.loginGateContainer.visibility = android.view.View.VISIBLE
                                binding.authenticatedRuntimeContainer.visibility = android.view.View.GONE
                                if (wasAuthenticated) {
                                    scannerSourceBinding.stop()
                                }
                            }

                            is AppSessionRoute.Authenticated -> {
                                val becameAuthenticated = !isAuthenticatedRouteActive
                                isAuthenticatedRouteActive = true
                                binding.loginGateContainer.visibility = android.view.View.GONE
                                binding.authenticatedRuntimeContainer.visibility = android.view.View.VISIBLE
                                if (becameAuthenticated) {
                                    diagnosticsViewModel.refresh()
                                    autoFlushCoordinator.requestFlush(AutoFlushTrigger.PostLogin)
                                }
                            }
                        }
                        syncScannerBindingForPermission()
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
                        binding.apiTargetValue.text = state.apiTargetLabel
                        binding.apiBaseUrlValue.text = state.apiBaseUrl
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
                        manualQueueInputController.render(state.ticketCodeInput)
                        binding.manualDirectionValue.text = state.directionLabel
                        binding.scanActionValue.text = state.lastActionMessage
                        binding.scanErrorValue.text =
                            state.validationMessage ?: getString(R.string.no_errors)
                        binding.queueScanButton.isEnabled = !state.isQueueing
                        binding.flushQueueButton.isEnabled = !state.isFlushing
                        binding.manualQueueDepthValue.text = "Queued locally: ${state.localQueueDepth}"
                        binding.manualUploadStateValue.text = state.uploadStateLabel
                        binding.manualServerResultHintValue.text = state.serverResultHint
                    }
                }

                launch {
                    scanningViewModel.uiState.collectLatest { state ->
                        binding.scannerPermissionValue.text = state.permissionSummary
                        binding.scannerStatusValue.text = state.scannerStatus
                        binding.requestCameraPermissionButton.isEnabled = state.isPermissionRequestEnabled
                        binding.requestCameraPermissionButton.visibility =
                            if (state.isPermissionRequestVisible) {
                                android.view.View.VISIBLE
                            } else {
                                android.view.View.GONE
                            }
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

        syncScannerBindingForPermission()
        sessionGateViewModel.refreshSessionRoute()
    }

    override fun onStart() {
        super.onStart()
        autoFlushCoordinator.requestFlush(AutoFlushTrigger.ForegroundResume)
        syncScannerBindingForPermission()
    }

    override fun onResume() {
        super.onResume()
        syncScannerBindingForPermission()
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

    private fun syncScannerBindingForPermission() {
        val hasPermission = hasCameraPermission()
        scanningViewModel.refreshPermissionState(hasPermission)

        val decision =
            scannerSourceActivationPolicy.evaluate(
                sourceMode = selectedScannerSourceMode,
                hasCameraPermission = hasPermission,
                isShellStarted =
                    lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED) &&
                        isAuthenticatedRouteActive
            )

        if (decision.shouldStartBinding) {
            scannerSourceBinding.start()
        } else {
            scannerSourceBinding.stop()
        }
    }

    private fun createScannerInputSource(
        sourceMode: ScannerShellSourceMode
    ): ScannerInputSource =
        when (sourceMode) {
            ScannerShellSourceMode.CAMERA ->
                CameraScannerInputSource(
                    scannerCameraBinder = scannerCameraBinder,
                    lifecycleOwnerProvider = { this },
                    previewViewProvider = { binding.scannerPreview },
                    appDispatchers = appDispatchers,
                    clock = clock,
                    barcodeScannerEngine = barcodeScannerEngine
                )
            ScannerShellSourceMode.DATAWEDGE ->
                DataWedgeScannerInputSource(
                    appContext = applicationContext,
                    appDispatchers = appDispatchers,
                    clock = clock
                )
        }

    private companion object {
        const val LOG_TAG: String = "FastCheckMainActivity"
    }
}
