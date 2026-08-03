package za.co.voelgoed.fastcheck.app

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.provider.Settings
import android.util.Log
import androidx.activity.ComponentActivity
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.platform.ViewCompositionStrategy
import androidx.core.app.ActivityCompat
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
import za.co.voelgoed.fastcheck.app.navigation.AppShellDestination
import za.co.voelgoed.fastcheck.app.navigation.AppShellOverflowAction
import za.co.voelgoed.fastcheck.app.scanning.ScanPreviewSurfaceHolder
import za.co.voelgoed.fastcheck.app.scanning.ScannerBlockReason
import za.co.voelgoed.fastcheck.app.scanning.ScannerActivationContext
import za.co.voelgoed.fastcheck.app.scanning.ScannerSessionState
import za.co.voelgoed.fastcheck.app.scanning.ScannerShellSourceMode
import za.co.voelgoed.fastcheck.app.scanning.ScannerSourceActivationDecision
import za.co.voelgoed.fastcheck.app.scanning.ScannerSourceActivationPolicy
import za.co.voelgoed.fastcheck.app.scanning.ScannerSourceSelectionResolver
import za.co.voelgoed.fastcheck.app.session.AppSessionRoute
import za.co.voelgoed.fastcheck.app.session.SessionGateViewModel
import za.co.voelgoed.fastcheck.app.shell.AppShellSupportRoute
import za.co.voelgoed.fastcheck.app.shell.AppShellViewModel
import za.co.voelgoed.fastcheck.app.shell.AuthenticatedShellScreen
import za.co.voelgoed.fastcheck.core.autoflush.AutoFlushCoordinator
import za.co.voelgoed.fastcheck.core.autoflush.AutoFlushTrigger
import za.co.voelgoed.fastcheck.core.sync.AttendeeSyncOrchestrator
import za.co.voelgoed.fastcheck.core.common.AppDispatchers
import za.co.voelgoed.fastcheck.core.network.ApiEnvironmentConfig
import za.co.voelgoed.fastcheck.databinding.ActivityMainBinding
import za.co.voelgoed.fastcheck.feature.auth.AuthEffect
import za.co.voelgoed.fastcheck.feature.auth.AuthViewModel
import za.co.voelgoed.fastcheck.feature.diagnostics.DiagnosticsViewModel
import za.co.voelgoed.fastcheck.feature.event.EventDestinationRoute
import za.co.voelgoed.fastcheck.feature.event.EventBucketsViewModel
import za.co.voelgoed.fastcheck.feature.event.EventMetricsViewModel
import za.co.voelgoed.fastcheck.feature.event.model.EventOperatorAction
import za.co.voelgoed.fastcheck.feature.queue.QueueViewModel
import za.co.voelgoed.fastcheck.feature.search.SearchDestinationRoute
import za.co.voelgoed.fastcheck.feature.search.SearchViewModel
import za.co.voelgoed.fastcheck.feature.scanning.analysis.BarcodeScannerEngine
import za.co.voelgoed.fastcheck.feature.scanning.broadcast.DataWedgeScannerInputSource
import za.co.voelgoed.fastcheck.feature.scanning.camera.CameraScannerInputSource
import za.co.voelgoed.fastcheck.feature.scanning.camera.ScannerCameraBinder
import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerInputSource
import za.co.voelgoed.fastcheck.feature.scanning.screen.ScanDestinationRoute
import za.co.voelgoed.fastcheck.feature.scanning.screen.model.ScanOperatorAction
import za.co.voelgoed.fastcheck.feature.scanning.ui.ScanningViewModel
import za.co.voelgoed.fastcheck.feature.scanning.ui.model.ScannerRecoveryState
import za.co.voelgoed.fastcheck.feature.scanning.usecase.CaptureHandoffResult
import za.co.voelgoed.fastcheck.feature.scanning.usecase.ScanCapturePipeline
import za.co.voelgoed.fastcheck.feature.scanning.usecase.ScannerSourceBinding
import za.co.voelgoed.fastcheck.feature.support.SupportDiagnosticsRoute
import za.co.voelgoed.fastcheck.feature.support.SupportOverviewRoute
import za.co.voelgoed.fastcheck.feature.support.SupportRecoveryAction
import za.co.voelgoed.fastcheck.feature.support.model.SupportOperationalAction
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

    @Inject
    lateinit var attendeeSyncOrchestrator: AttendeeSyncOrchestrator

    private val authViewModel: AuthViewModel by viewModels()
    private val sessionGateViewModel: SessionGateViewModel by viewModels()
    private val appShellViewModel: AppShellViewModel by viewModels()
    private val syncViewModel: SyncViewModel by viewModels()
    private val queueViewModel: QueueViewModel by viewModels()
    private val scanningViewModel: ScanningViewModel by viewModels()
    private val eventMetricsViewModel: EventMetricsViewModel by viewModels()
    private val diagnosticsViewModel: DiagnosticsViewModel by viewModels()
    private val eventBucketsViewModel: EventBucketsViewModel by viewModels()
    private val searchViewModel: SearchViewModel by viewModels()

    private val scannerSourceSelectionResolver = ScannerSourceSelectionResolver()
    private val scannerSourceActivationPolicy = ScannerSourceActivationPolicy()
    private val previewSurfaceHolder = ScanPreviewSurfaceHolder()

    private lateinit var selectedScannerSourceMode: ScannerShellSourceMode
    private lateinit var scannerInputSource: ScannerInputSource
    private lateinit var scannerSourceBinding: ScannerSourceBinding

    private var isAuthenticatedRouteActive: Boolean = false
    private var isScanDestinationActive: Boolean = true
    private var lastBootstrappedSessionKey: AuthenticatedSessionKey? = null
    private var hasAutoRequestedCameraPermissionThisScanEntry: Boolean = false

    private val cameraPermissionLauncher =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
            scanningViewModel.refreshPermissionState(
                isGranted = granted,
                shouldShowRationale = shouldShowCameraPermissionRationale()
            )
            syncScannerBindingState()
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        attendeeSyncOrchestrator.start()
        binding = ActivityMainBinding.inflate(layoutInflater)
        setContentView(binding.root)
        binding.authenticatedShellComposeView.setViewCompositionStrategy(
            ViewCompositionStrategy.DisposeOnViewTreeLifecycleDestroyed
        )
        binding.authenticatedShellComposeView.setContent {
            val shellUiState by appShellViewModel.uiState.collectAsState()
            val sessionRoute by sessionGateViewModel.route.collectAsState()
            val routeSession = (sessionRoute as? AppSessionRoute.Authenticated)?.session

            AuthenticatedShellScreen(
                uiState = shellUiState,
                onDestinationSelected = appShellViewModel::selectDestination,
                onOverflowActionSelected = ::handleShellOverflowAction,
                onNavigateBack = appShellViewModel::navigateBack,
                onLogoutConfirmationDismissed = appShellViewModel::dismissLogoutConfirmation,
                onLogoutConfirmed = ::confirmLogout,
                scanContent = {
                    if (routeSession != null) {
                        ScanDestinationRoute(
                            session = routeSession,
                            scanningViewModel = scanningViewModel,
                            queueViewModel = queueViewModel,
                            syncViewModel = syncViewModel,
                            previewSurfaceHolder = previewSurfaceHolder,
                            onPreviewSurfaceChanged = ::syncScannerBindingState,
                            onOperatorAction = ::handleScanOperatorAction
                        )
                    }
                },
                searchContent = {
                    if (routeSession != null) {
                        SearchDestinationRoute(
                            session = routeSession,
                            searchViewModel = searchViewModel,
                            syncViewModel = syncViewModel
                        )
                    }
                },
                eventContent = {
                    if (routeSession != null) {
                        EventDestinationRoute(
                            session = routeSession,
                            eventMetricsViewModel = eventMetricsViewModel,
                            queueViewModel = queueViewModel,
                            syncViewModel = syncViewModel,
                            eventBucketsViewModel = eventBucketsViewModel,
                            onOperatorAction = ::handleEventOperatorAction,
                            onViewParkedEvents = appShellViewModel::openDiagnostics
                        )
                    }
                },
                supportOverviewContent = {
                    SupportOverviewRoute(
                        session = routeSession,
                        eventMetricsViewModel = eventMetricsViewModel,
                        scanningViewModel = scanningViewModel,
                        queueViewModel = queueViewModel,
                        syncViewModel = syncViewModel,
                        onViewDiagnostics = appShellViewModel::openDiagnostics,
                        onRecoveryActionSelected = ::handleSupportRecoveryAction,
                        onOperationalAction = ::handleSupportOperationalAction,
                        onLogoutRequested = ::handleLogoutRequest
                    )
                },
                diagnosticsContent = {
                    SupportDiagnosticsRoute(
                        diagnosticsViewModel = diagnosticsViewModel
                    )
                }
            )
        }

        Log.i(
            LOG_TAG,
            "FastCheck API target=${apiEnvironmentConfig.target.wireName} baseUrl=${apiEnvironmentConfig.baseUrl}"
        )

        selectedScannerSourceMode = scannerSourceSelectionResolver.resolve()
        Log.i(LOG_TAG, "Active scanner source=${selectedScannerSourceMode.wireName}")
        scanningViewModel.onActiveSourceTypeChanged(selectedScannerSourceMode.sourceType)

        scannerInputSource = createScannerInputSource(selectedScannerSourceMode)
        scannerSourceBinding =
            ScannerSourceBinding(
                source = scannerInputSource,
                decodedBarcodeHandler = scanCapturePipeline,
                parentScope = lifecycleScope
            )

        binding.loginButton.setOnClickListener {
            if (sessionGateViewModel.route.value != AppSessionRoute.LoggedOut) {
                return@setOnClickListener
            }
            authViewModel.updateEventId(binding.eventIdInput.text.toString())
            authViewModel.updateCredential(binding.credentialInput.text.toString())
            authViewModel.login()
        }

        lifecycleScope.launch {
            repeatOnLifecycle(Lifecycle.State.STARTED) {
                launch {
                    authViewModel.uiState.collectLatest { state ->
                        binding.sessionSummaryValue.text = getString(R.string.no_active_session)
                        binding.authErrorValue.text =
                            state.errorMessage ?: getString(R.string.no_errors)
                        if (binding.eventIdInput.text.toString() != state.eventIdInput) {
                            binding.eventIdInput.setText(state.eventIdInput)
                        }
                        if (binding.credentialInput.text.toString() != state.credentialInput) {
                            binding.credentialInput.setText(state.credentialInput)
                        }
                        updateLoginButtonEnabled()
                    }
                }

                launch {
                    authViewModel.effects.collectLatest { effect ->
                        when (effect) {
                            AuthEffect.LoginCommitted -> sessionGateViewModel.onLoginCommitted()
                        }
                    }
                }

                launch {
                    sessionGateViewModel.recoveryMessage.collectLatest { message ->
                        if (message != null) {
                            authViewModel.setExternalError(message)
                        }
                    }
                }

                launch {
                    sessionGateViewModel.route.collectLatest { route ->
                        var shouldEvaluateAutoRequestOnScanEntry = false
                        when (route) {
                            AppSessionRoute.RestoringSession,
                            AppSessionRoute.LoggingOut,
                            AppSessionRoute.LoggedOut -> {
                                if (route == AppSessionRoute.LoggingOut) {
                                    authViewModel.resetAfterLogout()
                                }
                                val wasAuthenticated = isAuthenticatedRouteActive
                                isAuthenticatedRouteActive = false
                                lastBootstrappedSessionKey = null
                                hasAutoRequestedCameraPermissionThisScanEntry = false
                                syncViewModel.resetBootstrapState()
                                appShellViewModel.reset()
                                binding.loginGateContainer.visibility = android.view.View.VISIBLE
                                binding.authenticatedShellComposeView.visibility =
                                    android.view.View.GONE
                                if (wasAuthenticated) {
                                    scannerSourceBinding.stop()
                                }
                                attendeeSyncOrchestrator.notifyScanDestinationInactive()
                            }

                            is AppSessionRoute.Authenticated -> {
                                val becameAuthenticated = !isAuthenticatedRouteActive
                                val sessionKey = AuthenticatedSessionKey.from(route.session)
                                val sessionChanged = lastBootstrappedSessionKey != sessionKey
                                isAuthenticatedRouteActive = true
                                if (becameAuthenticated) {
                                    appShellViewModel.reset()
                                }
                                if (sessionChanged) {
                                    hasAutoRequestedCameraPermissionThisScanEntry = false
                                    syncViewModel.resetBootstrapState()
                                    syncViewModel.beginAuthenticatedEventBootstrap(route.session.eventId)
                                    lastBootstrappedSessionKey = sessionKey
                                }
                                binding.loginGateContainer.visibility = android.view.View.GONE
                                binding.authenticatedShellComposeView.visibility =
                                    android.view.View.VISIBLE
                                if (sessionChanged) {
                                    autoFlushCoordinator.requestFlush(AutoFlushTrigger.PostLogin)
                                }
                                shouldEvaluateAutoRequestOnScanEntry =
                                    isScanDestinationActive && (becameAuthenticated || sessionChanged)
                                if (isScanDestinationActive) {
                                    attendeeSyncOrchestrator.notifyScanDestinationActive()
                                }
                            }
                        }
                        updateLoginButtonEnabled()
                        val decision = syncScannerBindingState()
                        if (shouldEvaluateAutoRequestOnScanEntry) {
                            maybeAutoRequestCameraPermissionOnScanEntry(decision)
                        }
                    }
                }

                launch {
                    appShellViewModel.uiState.collectLatest { state ->
                        val wasScanDestinationActive = isScanDestinationActive
                        isScanDestinationActive = isScanSurfaceReallyActive(
                            selectedDestination = state.selectedDestination,
                            activeSupportRoute = state.activeSupportRoute
                        )
                        val enteredScan = !wasScanDestinationActive && isScanDestinationActive
                        val exitedScan = wasScanDestinationActive && !isScanDestinationActive
                        if (enteredScan) {
                            hasAutoRequestedCameraPermissionThisScanEntry = false
                            attendeeSyncOrchestrator.notifyScanDestinationActive()
                        } else if (exitedScan) {
                            attendeeSyncOrchestrator.notifyScanDestinationInactive()
                        }
                        val decision = syncScannerBindingState()
                        if (enteredScan) {
                            maybeAutoRequestCameraPermissionOnScanEntry(decision)
                        }
                    }
                }

                launch {
                    var lastWasSyncing = false
                    var lastError: String? = null
                    syncViewModel.uiState.collectLatest { state ->
                        val completedNow = lastWasSyncing && !state.isSyncing
                        val succeededNow =
                            completedNow && lastError == null && state.errorMessage == null
                        if (succeededNow) {
                            autoFlushCoordinator.requestFlush(AutoFlushTrigger.PostSync)
                        }

                        lastWasSyncing = state.isSyncing
                        lastError = state.errorMessage
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
                        if (result is CaptureHandoffResult.Accepted) {
                            autoFlushCoordinator.requestFlush(AutoFlushTrigger.AfterEnqueue)
                        }
                    }
                }

                launch {
                    scanCapturePipeline.decodeDiagnostics.collectLatest { diagnostic ->
                        scanningViewModel.onDecodeDiagnostic(diagnostic)
                        Log.d(LOG_TAG, "decode_diagnostic=$diagnostic")
                    }
                }
            }
        }

        syncScannerBindingState()
    }

    override fun onStart() {
        super.onStart()
        autoFlushCoordinator.requestFlush(AutoFlushTrigger.ForegroundResume)
        syncScannerBindingState()
    }

    override fun onResume() {
        super.onResume()
        syncScannerBindingState()
        if (appShellViewModel.uiState.value.activeSupportRoute == AppShellSupportRoute.Diagnostics) {
            diagnosticsViewModel.refresh()
        }
    }

    override fun onStop() {
        attendeeSyncOrchestrator.notifyScanDestinationInactive()
        scanningViewModel.onActivationDecision(
            ScannerSourceActivationDecision(
                shouldStartBinding = false,
                shouldShowCameraPermissionRequest = false,
                sessionState = ScannerSessionState.Blocked(ScannerBlockReason.Backgrounded)
            )
        )
        scanningViewModel.onBindingAttemptChanged(false)
        scannerSourceBinding.stop()
        super.onStop()
    }

    private fun hasCameraPermission(): Boolean =
        MainActivityTestHooks.permissionStateOverride?.isGranted
            ?: (
                ContextCompat.checkSelfPermission(
                    this,
                    android.Manifest.permission.CAMERA
                ) == android.content.pm.PackageManager.PERMISSION_GRANTED
            )

    private fun shouldShowCameraPermissionRationale(): Boolean =
        MainActivityTestHooks.permissionStateOverride?.shouldShowRationale
            ?: ActivityCompat.shouldShowRequestPermissionRationale(
                this,
                android.Manifest.permission.CAMERA
            )

    private fun syncScannerBindingState(): ScannerSourceActivationDecision {
        val hasPermission = hasCameraPermission()
        scanningViewModel.refreshPermissionState(
            isGranted = hasPermission,
            shouldShowRationale = shouldShowCameraPermissionRationale()
        )
        val hasPreviewSurface =
            MainActivityTestHooks.previewSurfaceOverride?.hasPreviewSurface
                ?: previewSurfaceHolder.hasPreviewSurface()
        val isPreviewVisible =
            MainActivityTestHooks.previewSurfaceOverride?.isPreviewVisible
                ?: previewSurfaceHolder.isPreviewVisible()
        scanningViewModel.onPreviewSurfaceStateChanged(
            hasPreviewSurface = hasPreviewSurface,
            isPreviewVisible = isPreviewVisible
        )

        val decision =
            scannerSourceActivationPolicy.evaluate(
                ScannerActivationContext(
                    sourceMode = selectedScannerSourceMode,
                    isAuthenticated = isAuthenticatedRouteActive,
                    isScanDestinationSelected = isScanDestinationActive,
                    isForeground = lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED),
                    hasCameraPermission = hasPermission,
                    hasPreviewSurface = hasPreviewSurface,
                    isPreviewVisible = isPreviewVisible
                )
            )
        val eventId = lastBootstrappedSessionKey?.eventId
        Log.i(
            LOG_TAG,
            "scanner_activation_evaluated " +
                "eventId=${eventId ?: -1} " +
                "source=${selectedScannerSourceMode.wireName} " +
                "isAuthenticated=$isAuthenticatedRouteActive " +
                "isScanDestinationActive=$isScanDestinationActive " +
                "hasPreviewSurface=$hasPreviewSurface " +
                "isPreviewVisible=$isPreviewVisible " +
                "hasPermission=$hasPermission " +
                "shouldStartBinding=${decision.shouldStartBinding} " +
                "sessionState=${decision.sessionState::class.simpleName}"
        )

        scanningViewModel.onActivationDecision(decision)

        if (decision.shouldStartBinding) {
            scanningViewModel.onBindingAttemptChanged(true)
            Log.i(LOG_TAG, "scanner_binding_start_requested eventId=${eventId ?: -1}")
            scannerSourceBinding.start()
        } else {
            scanningViewModel.onBindingAttemptChanged(false)
            Log.i(LOG_TAG, "scanner_binding_stop_requested eventId=${eventId ?: -1}")
            scannerSourceBinding.stop()
        }

        return decision
    }

    private fun handleShellOverflowAction(action: AppShellOverflowAction) {
        if (sessionGateViewModel.route.value !is AppSessionRoute.Authenticated) return
        when (action) {
            AppShellOverflowAction.Support ->
                appShellViewModel.onOverflowActionSelected(action)

            AppShellOverflowAction.Logout ->
                handleLogoutRequest()
        }
    }

    private fun handleLogoutRequest() {
        if (sessionGateViewModel.route.value !is AppSessionRoute.Authenticated) return
        val queueDepth = queueViewModel.uiState.value.localQueueDepth
        val needsConfirmation = appShellViewModel.requestLogout(queueDepth)
        if (!needsConfirmation) {
            sessionGateViewModel.logout()
        }
    }

    private fun confirmLogout() {
        if (sessionGateViewModel.route.value !is AppSessionRoute.Authenticated) return
        appShellViewModel.dismissLogoutConfirmation()
        hasAutoRequestedCameraPermissionThisScanEntry = false
        sessionGateViewModel.logout()
    }

    private fun handleSupportRecoveryAction(action: SupportRecoveryAction) {
        if (sessionGateViewModel.route.value !is AppSessionRoute.Authenticated) return
        when (action) {
            SupportRecoveryAction.RequestCameraAccess -> {
                launchCameraPermissionRequest()
            }

            SupportRecoveryAction.OpenAppSettings ->
                openAppSettings()

            SupportRecoveryAction.ReturnToScan ->
                appShellViewModel.selectDestination(AppShellDestination.Scan)
        }
    }

    private fun handleEventOperatorAction(action: EventOperatorAction) {
        if (sessionGateViewModel.route.value !is AppSessionRoute.Authenticated) return
        when (action) {
            EventOperatorAction.ManualSync -> syncViewModel.syncAttendees()
            EventOperatorAction.RetryUpload -> queueViewModel.flushQueuedScans()
            EventOperatorAction.Relogin -> handleReloginForAuthExpired()
        }
    }

    private fun handleScanOperatorAction(action: ScanOperatorAction) {
        if (sessionGateViewModel.route.value !is AppSessionRoute.Authenticated) return
        when (action) {
            ScanOperatorAction.RequestCameraAccess -> launchCameraPermissionRequest()
            ScanOperatorAction.OpenAppSettings -> openAppSettings()
            ScanOperatorAction.ReconnectCamera -> {
                scannerSourceBinding.stop()
                syncScannerBindingState()
            }
            ScanOperatorAction.ManualSync -> syncViewModel.syncAttendees()
            ScanOperatorAction.RetryUpload -> queueViewModel.flushQueuedScans()
            ScanOperatorAction.Relogin -> handleReloginForAuthExpired()
        }
    }

    private fun handleSupportOperationalAction(action: SupportOperationalAction) {
        if (sessionGateViewModel.route.value !is AppSessionRoute.Authenticated) return
        when (action) {
            SupportOperationalAction.ManualSync -> syncViewModel.syncAttendees()
            SupportOperationalAction.RetryUpload -> queueViewModel.flushQueuedScans()
            SupportOperationalAction.Relogin -> handleReloginForAuthExpired()
        }
    }

    /**
     * Auth-expired re-login: route through session logout without the generic
     * "queued scans" logout confirmation dialog (that reads as destructive shutdown).
     * Queued scans remain in local storage; operator signs in again to resume uploads.
     */
    private fun handleReloginForAuthExpired() {
        if (sessionGateViewModel.route.value !is AppSessionRoute.Authenticated) return
        appShellViewModel.dismissLogoutConfirmation()
        hasAutoRequestedCameraPermissionThisScanEntry = false
        sessionGateViewModel.logout()
    }

    private fun updateLoginButtonEnabled() {
        binding.loginButton.isEnabled =
            sessionGateViewModel.route.value == AppSessionRoute.LoggedOut &&
                !authViewModel.uiState.value.isSubmitting
    }

    private fun launchCameraPermissionRequest() {
        scanningViewModel.onPermissionRequestStarted()
        MainActivityTestHooks.onCameraPermissionRequest?.let { onRequest ->
            onRequest()
            return
        }
        cameraPermissionLauncher.launch(android.Manifest.permission.CAMERA)
    }

    private fun openAppSettings() {
        val intent = appSettingsIntent(packageName)
        MainActivityTestHooks.onOpenAppSettings?.let { onOpen ->
            onOpen(intent)
            return
        }
        startActivity(intent)
    }

    private fun maybeAutoRequestCameraPermissionOnScanEntry(
        decision: ScannerSourceActivationDecision
    ) {
        if (
            !shouldAutoRequestCameraPermissionOnScanEntry(
                sourceMode = selectedScannerSourceMode,
                isAuthenticated = isAuthenticatedRouteActive,
                isScanDestinationSelected = isScanDestinationActive,
                isForeground = lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED),
                hasCameraPermission = hasCameraPermission(),
                shouldShowCameraPermissionRequest = decision.shouldShowCameraPermissionRequest,
                recoveryState = scanningViewModel.uiState.value.scannerRecoveryState,
                hasAutoRequestedCameraPermissionThisScanEntry =
                    hasAutoRequestedCameraPermissionThisScanEntry
            )
        ) {
            return
        }

        hasAutoRequestedCameraPermissionThisScanEntry = true
        launchCameraPermissionRequest()
    }

    private fun createScannerInputSource(sourceMode: ScannerShellSourceMode): ScannerInputSource =
        MainActivityTestHooks.scannerInputSourceFactory?.invoke(sourceMode)
            ?: when (sourceMode) {
                ScannerShellSourceMode.CAMERA ->
                    CameraScannerInputSource(
                        scannerCameraBinder = scannerCameraBinder,
                        lifecycleOwnerProvider = { this },
                        previewViewProvider = { previewSurfaceHolder.requirePreviewView() },
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

internal fun isScanSurfaceReallyActive(
    selectedDestination: AppShellDestination,
    activeSupportRoute: AppShellSupportRoute?
): Boolean =
    selectedDestination == AppShellDestination.Scan && activeSupportRoute == null

internal fun shouldAutoRequestCameraPermissionOnScanEntry(
    sourceMode: ScannerShellSourceMode,
    isAuthenticated: Boolean,
    isScanDestinationSelected: Boolean,
    isForeground: Boolean,
    hasCameraPermission: Boolean,
    shouldShowCameraPermissionRequest: Boolean,
    recoveryState: ScannerRecoveryState,
    hasAutoRequestedCameraPermissionThisScanEntry: Boolean
): Boolean =
    sourceMode.requiresCameraPermission &&
        isAuthenticated &&
        isScanDestinationSelected &&
        isForeground &&
        !hasCameraPermission &&
        shouldShowCameraPermissionRequest &&
        !hasAutoRequestedCameraPermissionThisScanEntry &&
        recoveryState is ScannerRecoveryState.RequestPermission

internal fun appSettingsIntent(packageName: String): Intent =
    Intent(
        Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
        Uri.fromParts("package", packageName, null)
    )

internal data class AuthenticatedSessionKey(
    val eventId: Long,
    val sessionGeneration: Long?,
    val authenticatedAtEpochMillis: Long
) {
    companion object {
        fun from(session: za.co.voelgoed.fastcheck.domain.model.ScannerSession): AuthenticatedSessionKey =
            AuthenticatedSessionKey(
                eventId = session.eventId,
                sessionGeneration = session.sessionGeneration,
                authenticatedAtEpochMillis = session.authenticatedAtEpochMillis
            )
    }
}
