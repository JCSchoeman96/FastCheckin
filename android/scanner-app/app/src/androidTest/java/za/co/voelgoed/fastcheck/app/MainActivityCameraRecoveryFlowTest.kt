package za.co.voelgoed.fastcheck.app

import android.content.Intent
import android.os.SystemClock
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.google.common.truth.Truth.assertThat
import dagger.hilt.android.testing.HiltAndroidRule
import dagger.hilt.android.testing.HiltAndroidTest
import java.util.ArrayDeque
import java.util.Collections
import java.util.concurrent.atomic.AtomicInteger
import javax.inject.Inject
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.emptyFlow
import org.junit.After
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import za.co.voelgoed.fastcheck.app.navigation.AppShellDestination
import za.co.voelgoed.fastcheck.app.session.SessionGateViewModel
import za.co.voelgoed.fastcheck.app.shell.AppShellViewModel
import za.co.voelgoed.fastcheck.di.TestSessionRepository
import za.co.voelgoed.fastcheck.domain.model.ScannerSession
import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerCaptureEvent
import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerInputSource
import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerSourceState
import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerSourceType
import za.co.voelgoed.fastcheck.feature.scanning.screen.model.ScanOperatorAction
import za.co.voelgoed.fastcheck.feature.scanning.ui.ScanningViewModel
import za.co.voelgoed.fastcheck.feature.scanning.ui.model.ScannerRecoveryState

@HiltAndroidTest
@RunWith(AndroidJUnit4::class)
class MainActivityCameraRecoveryFlowTest {
    @get:Rule
    var hiltRule = HiltAndroidRule(this)

    @Inject
    lateinit var testSessionRepository: TestSessionRepository

    @Before
    fun setUp() {
        MainActivityTestHooks.reset()
        hiltRule.inject()
        testSessionRepository.setCurrentSession(null)
    }

    @After
    fun tearDown() {
        testSessionRepository.setCurrentSession(null)
        MainActivityTestHooks.reset()
    }

    @Test
    fun leavingScanAndReturningResetsAutoRequestLatch() {
        val permissionRequests = AtomicInteger(0)
        MainActivityTestHooks.permissionStateOverride =
            CameraPermissionOverride(isGranted = false, shouldShowRationale = true)
        MainActivityTestHooks.onCameraPermissionRequest = permissionRequests::incrementAndGet

        val scenario = launchActivity()
        try {
            authenticate(scenario, session(eventId = 5, authenticatedAtEpochMillis = 1_700_000_000_000))
            waitUntil("initial camera auto-request") { permissionRequests.get() == 1 }

            scenario.onActivity { activity ->
                viewModel<AppShellViewModel>(activity).selectDestination(AppShellDestination.Event)
            }
            waitForIdle()
            assertThat(permissionRequests.get()).isEqualTo(1)

            scenario.onActivity { activity ->
                viewModel<AppShellViewModel>(activity).selectDestination(AppShellDestination.Scan)
            }
            waitUntil("camera auto-request after returning to Scan") {
                permissionRequests.get() == 2
            }
        } finally {
            scenario.close()
        }
    }

    @Test
    fun sessionChangeResetsAutoRequestLatch() {
        val permissionRequests = AtomicInteger(0)
        MainActivityTestHooks.permissionStateOverride =
            CameraPermissionOverride(isGranted = false, shouldShowRationale = true)
        MainActivityTestHooks.onCameraPermissionRequest = permissionRequests::incrementAndGet

        val scenario = launchActivity()
        try {
            authenticate(scenario, session(eventId = 5, authenticatedAtEpochMillis = 1_700_000_000_000))
            waitUntil("initial camera auto-request") { permissionRequests.get() == 1 }

            scenario.onActivity { activity ->
                viewModel<SessionGateViewModel>(activity).onLoginSucceeded(
                    session(eventId = 5, authenticatedAtEpochMillis = 1_700_000_100_000)
                )
            }
            waitUntil("camera auto-request after session change") {
                permissionRequests.get() == 2
            }
        } finally {
            scenario.close()
        }
    }

    @Test
    fun manualRequestStillLaunchesAfterAutoRequest() {
        val permissionRequests = AtomicInteger(0)
        MainActivityTestHooks.permissionStateOverride =
            CameraPermissionOverride(isGranted = false, shouldShowRationale = true)
        MainActivityTestHooks.onCameraPermissionRequest = permissionRequests::incrementAndGet

        val scenario = launchActivity()
        try {
            authenticate(scenario, session(eventId = 5, authenticatedAtEpochMillis = 1_700_000_000_000))
            waitUntil("initial camera auto-request") { permissionRequests.get() == 1 }

            scenario.onActivity { activity ->
                activity.invokeHandleScanOperatorAction(ScanOperatorAction.RequestCameraAccess)
            }
            waitUntil("manual camera permission request") { permissionRequests.get() == 2 }
        } finally {
            scenario.close()
        }
    }

    @Test
    fun reconnectStopsAndRestartsScannerWhenActivationStillAllowsScanning() {
        val fakeSource =
            FakeScannerInputSource().apply {
                enqueueStateOnStart(ScannerSourceState.Error("camera unavailable"))
                enqueueStateOnStart(ScannerSourceState.Ready)
            }
        MainActivityTestHooks.permissionStateOverride =
            CameraPermissionOverride(isGranted = true, shouldShowRationale = false)
        MainActivityTestHooks.previewSurfaceOverride =
            PreviewSurfaceOverride(hasPreviewSurface = true, isPreviewVisible = true)
        MainActivityTestHooks.scannerInputSourceFactory = { fakeSource }

        val scenario = launchActivity()
        try {
            authenticate(scenario, session(eventId = 5, authenticatedAtEpochMillis = 1_700_000_000_000))
            waitUntil("initial scanner start") {
                fakeSource.startCount == 1 && fakeSource.state.value is ScannerSourceState.Error
            }

            scenario.onActivity { activity ->
                activity.invokeHandleScanOperatorAction(ScanOperatorAction.ReconnectCamera)
            }
            waitUntil("scanner reconnect restart") {
                fakeSource.startCount == 2 &&
                    fakeSource.stopCount == 1 &&
                    fakeSource.state.value is ScannerSourceState.Ready
            }
        } finally {
            scenario.close()
        }
    }

    @Test
    fun reconnectStopsWithoutRestartWhenActivationNoLongerAllowsScanning() {
        val fakeSource =
            FakeScannerInputSource().apply {
                enqueueStateOnStart(ScannerSourceState.Error("camera unavailable"))
            }
        MainActivityTestHooks.permissionStateOverride =
            CameraPermissionOverride(isGranted = true, shouldShowRationale = false)
        MainActivityTestHooks.previewSurfaceOverride =
            PreviewSurfaceOverride(hasPreviewSurface = true, isPreviewVisible = true)
        MainActivityTestHooks.scannerInputSourceFactory = { fakeSource }

        val scenario = launchActivity()
        try {
            authenticate(scenario, session(eventId = 5, authenticatedAtEpochMillis = 1_700_000_000_000))
            waitUntil("initial scanner start") {
                fakeSource.startCount == 1 && fakeSource.state.value is ScannerSourceState.Error
            }

            MainActivityTestHooks.previewSurfaceOverride =
                PreviewSurfaceOverride(hasPreviewSurface = false, isPreviewVisible = false)

            scenario.onActivity { activity ->
                activity.invokeHandleScanOperatorAction(ScanOperatorAction.ReconnectCamera)
            }
            waitUntil("scanner stop without restart") { fakeSource.stopCount == 1 }
            assertRemains("scanner restart count", expected = 1) { fakeSource.startCount }
        } finally {
            scenario.close()
        }
    }

    @Test
    fun settingsOnlyRecoveryDoesNotAutoRequestOnReentryAndStillLaunchesSettings() {
        val permissionRequests = AtomicInteger(0)
        val launchedSettingsIntents = Collections.synchronizedList(mutableListOf<Intent>())
        MainActivityTestHooks.permissionStateOverride =
            CameraPermissionOverride(isGranted = false, shouldShowRationale = false)
        MainActivityTestHooks.onCameraPermissionRequest = permissionRequests::incrementAndGet
        MainActivityTestHooks.onOpenAppSettings = launchedSettingsIntents::add

        val scenario = launchActivity()
        try {
            scenario.onActivity { activity ->
                val scanningViewModel = viewModel<ScanningViewModel>(activity)
                scanningViewModel.refreshPermissionState(isGranted = false, shouldShowRationale = false)
                scanningViewModel.onPermissionRequestStarted()
                assertThat(scanningViewModel.uiState.value.scannerRecoveryState)
                    .isEqualTo(ScannerRecoveryState.OpenSystemSettings)
            }

            authenticate(scenario, session(eventId = 5, authenticatedAtEpochMillis = 1_700_000_000_000))
            waitForIdle()
            assertThat(permissionRequests.get()).isEqualTo(0)

            scenario.onActivity { activity ->
                viewModel<AppShellViewModel>(activity).selectDestination(AppShellDestination.Event)
            }
            waitForIdle()

            scenario.onActivity { activity ->
                viewModel<AppShellViewModel>(activity).selectDestination(AppShellDestination.Scan)
            }
            waitForIdle()
            assertThat(permissionRequests.get()).isEqualTo(0)

            scenario.onActivity { activity ->
                activity.invokeHandleScanOperatorAction(ScanOperatorAction.OpenAppSettings)
            }
            waitUntil("settings intent launch") { launchedSettingsIntents.size == 1 }

            val settingsIntent = launchedSettingsIntents.single()
            assertThat(settingsIntent.action)
                .isEqualTo(android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
            assertThat(settingsIntent.dataString)
                .isEqualTo("package:za.co.voelgoed.fastcheck")
        } finally {
            scenario.close()
        }
    }

    @Test
    fun firstEntryToScanStartsCameraSourceWithoutPreviewOverride() {
        val fakeSource = FakeScannerInputSource()
        MainActivityTestHooks.permissionStateOverride =
            CameraPermissionOverride(isGranted = true, shouldShowRationale = false)
        MainActivityTestHooks.scannerInputSourceFactory = { fakeSource }

        val scenario = launchActivity()
        try {
            authenticate(scenario, session(eventId = 5, authenticatedAtEpochMillis = 1_700_000_000_000))
            waitUntil("camera source start without preview override") {
                fakeSource.startCount == 1
            }
        } finally {
            scenario.close()
        }
    }

    @Test
    fun permissionGrantResyncStartsCameraSourceWithoutPreviewOverride() {
        val fakeSource = FakeScannerInputSource()
        MainActivityTestHooks.permissionStateOverride =
            CameraPermissionOverride(isGranted = false, shouldShowRationale = true)
        MainActivityTestHooks.scannerInputSourceFactory = { fakeSource }

        val scenario = launchActivity()
        try {
            authenticate(scenario, session(eventId = 5, authenticatedAtEpochMillis = 1_700_000_000_000))
            waitForIdle()
            assertThat(fakeSource.startCount).isEqualTo(0)

            MainActivityTestHooks.permissionStateOverride =
                CameraPermissionOverride(isGranted = true, shouldShowRationale = false)

            scenario.onActivity { activity ->
                activity.invokeSyncScannerBindingState()
            }

            waitUntil("camera source start after permission grant resync") {
                fakeSource.startCount == 1
            }
        } finally {
            scenario.close()
        }
    }

    @Test
    fun permissionGrantedScanStartupAttemptsCameraSourceWithoutPreviewOverride() {
        val fakeSource = FakeScannerInputSource()
        MainActivityTestHooks.permissionStateOverride =
            CameraPermissionOverride(isGranted = true, shouldShowRationale = false)
        MainActivityTestHooks.scannerInputSourceFactory = { fakeSource }

        val scenario = launchActivity()
        try {
            authenticate(scenario, session(eventId = 5, authenticatedAtEpochMillis = 1_700_000_000_000))
            waitUntil("camera source start") { fakeSource.startCount == 1 }
        } finally {
            scenario.close()
        }
    }

    private fun launchActivity(): ActivityScenario<MainActivity> =
        ActivityScenario.launch(MainActivity::class.java).also {
            waitForIdle()
        }

    private fun authenticate(
        scenario: ActivityScenario<MainActivity>,
        session: ScannerSession
    ) {
        scenario.onActivity { activity ->
            viewModel<SessionGateViewModel>(activity).onLoginSucceeded(session)
        }
        waitForIdle()
    }

    private fun session(
        eventId: Long,
        authenticatedAtEpochMillis: Long
    ): ScannerSession =
        testSessionRepository.session(
            eventId = eventId,
            authenticatedAtEpochMillis = authenticatedAtEpochMillis
        )

    private fun waitUntil(
        description: String,
        timeoutMs: Long = 5_000,
        predicate: () -> Boolean
    ) {
        val deadline = SystemClock.elapsedRealtime() + timeoutMs
        while (SystemClock.elapsedRealtime() < deadline) {
            waitForIdle()
            if (predicate()) {
                return
            }
            SystemClock.sleep(50)
        }

        throw AssertionError("Timed out waiting for $description.")
    }

    private fun assertRemains(
        description: String,
        expected: Int,
        durationMs: Long = 300,
        actual: () -> Int
    ) {
        val deadline = SystemClock.elapsedRealtime() + durationMs
        while (SystemClock.elapsedRealtime() < deadline) {
            waitForIdle()
            val current = actual()
            if (current != expected) {
                throw AssertionError(
                    "Expected $description to remain $expected, but was $current."
                )
            }
            SystemClock.sleep(25)
        }
    }

    private fun waitForIdle() {
        androidx.test.platform.app.InstrumentationRegistry.getInstrumentation().waitForIdleSync()
    }

    private inline fun <reified T : ViewModel> viewModel(activity: MainActivity): T =
        ViewModelProvider(activity)[T::class.java]

    private fun MainActivity.invokeHandleScanOperatorAction(action: ScanOperatorAction) {
        val method =
            MainActivity::class.java.getDeclaredMethod(
                "handleScanOperatorAction",
                ScanOperatorAction::class.java
            )
        method.isAccessible = true
        method.invoke(this, action)
    }

    private fun MainActivity.invokeSyncScannerBindingState() {
        val method =
            MainActivity::class.java.getDeclaredMethod("syncScannerBindingState")
        method.isAccessible = true
        method.invoke(this)
    }

    private class FakeScannerInputSource : ScannerInputSource {
        override val type: ScannerSourceType = ScannerSourceType.CAMERA
        override val id: String = "test-camera"

        private val queuedStates = ArrayDeque<ScannerSourceState>()
        private val mutableState = MutableStateFlow<ScannerSourceState>(ScannerSourceState.Idle)

        override val state: StateFlow<ScannerSourceState> = mutableState
        override val captures = emptyFlow<ScannerCaptureEvent>()

        var startCount: Int = 0
            private set

        var stopCount: Int = 0
            private set

        fun enqueueStateOnStart(state: ScannerSourceState) {
            queuedStates.addLast(state)
        }

        override fun start() {
            startCount += 1
            mutableState.value = queuedStates.pollFirst() ?: ScannerSourceState.Ready
        }

        override fun stop() {
            stopCount += 1
            mutableState.value = ScannerSourceState.Idle
        }
    }
}
