package za.co.voelgoed.fastcheck.app

import android.graphics.Bitmap
import android.os.SystemClock
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.google.common.truth.Truth.assertThat
import dagger.hilt.android.testing.HiltAndroidRule
import dagger.hilt.android.testing.HiltAndroidTest
import java.io.File
import java.io.FileOutputStream
import javax.inject.Inject
import org.junit.After
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import za.co.voelgoed.fastcheck.app.navigation.AppShellDestination
import za.co.voelgoed.fastcheck.app.navigation.AppShellOverflowAction
import za.co.voelgoed.fastcheck.app.session.AppSessionRoute
import za.co.voelgoed.fastcheck.app.session.SessionGateViewModel
import za.co.voelgoed.fastcheck.app.shell.AppShellViewModel
import za.co.voelgoed.fastcheck.data.local.ScannerDao
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.emptyFlow
import za.co.voelgoed.fastcheck.feature.auth.AuthViewModel
import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerCaptureEvent
import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerInputSource
import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerSourceState
import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerSourceType
import za.co.voelgoed.fastcheck.feature.sync.BootstrapSyncStatus
import za.co.voelgoed.fastcheck.feature.sync.SyncViewModel

/**
 * Captures Play Store listing screenshots on a running emulator or device.
 *
 * Requires a reachable mobile API (local emulator loopback or release) plus
 * instrumentation args `fastcheck.eventId` and `fastcheck.credential`.
 */
@HiltAndroidTest
@RunWith(AndroidJUnit4::class)
class PlayStoreScreenshotTest {
    @get:Rule
    var hiltRule = HiltAndroidRule(this)

    @Inject
    lateinit var scannerDao: ScannerDao

    @Before
    fun setUp() {
        MainActivityTestHooks.reset()
        assumeTrue(
            "Play Store screenshot capture requires fastcheck.eventId and fastcheck.credential.",
            hasRequiredArgs()
        )
        hiltRule.inject()
    }

    @After
    fun tearDown() {
        MainActivityTestHooks.reset()
    }

    @Test
    fun capturePlayStoreScreenshots() {
        val eventId = requiredLongArg("fastcheck.eventId")
        val credential = requiredStringArg("fastcheck.credential")
        val formFactor = optionalStringArg("fastcheck.formFactor") ?: "phone"

        configureStableVisualHooks()

        val scenario = ActivityScenario.launch(MainActivity::class.java)
        try {
            waitForIdle()
            capture(scenario, formFactor, "01_login")

            loginAndSync(scenario, eventId, credential)
            waitForIdle()
            capture(scenario, formFactor, "02_scan_ready")

            selectDestination(scenario, AppShellDestination.Search)
            capture(scenario, formFactor, "03_search")

            selectDestination(scenario, AppShellDestination.Event)
            capture(scenario, formFactor, "04_event")

            openSupportOverview(scenario)
            capture(scenario, formFactor, "05_support")
        } finally {
            scenario.close()
        }
    }

    private fun configureStableVisualHooks() {
        MainActivityTestHooks.permissionStateOverride =
            CameraPermissionOverride(isGranted = true, shouldShowRationale = false)
        MainActivityTestHooks.scannerInputSourceFactory = { FakeScannerInputSource() }
    }

    private fun capture(
        scenario: ActivityScenario<MainActivity>,
        formFactor: String,
        name: String
    ) {
        scenario.onActivity { activity ->
            val outputDir =
                File(
                    activity.filesDir,
                    "play-store-screenshots/$formFactor"
                )
            outputDir.mkdirs()
            val outputFile = File(outputDir, "$name.png")
            saveScreenshot(outputFile)
            assertThat(outputFile.exists()).isTrue()
            assertThat(outputFile.length()).isGreaterThan(0L)
        }
        SystemClock.sleep(250)
    }

    private fun saveScreenshot(outputFile: File) {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val screenshot =
            instrumentation.uiAutomation.takeScreenshot()
                ?: error("Unable to capture screenshot for ${outputFile.name}.")
        try {
            FileOutputStream(outputFile).use { stream ->
                if (!screenshot.compress(Bitmap.CompressFormat.PNG, 100, stream)) {
                    error("Failed to encode screenshot for ${outputFile.name}.")
                }
            }
        } finally {
            screenshot.recycle()
        }
    }

    private fun loginAndSync(
        scenario: ActivityScenario<MainActivity>,
        eventId: Long,
        credential: String
    ) {
        scenario.onActivity { activity ->
            val authViewModel = viewModel<AuthViewModel>(activity)
            authViewModel.updateEventId(eventId.toString())
            authViewModel.updateCredential(credential)
            authViewModel.login()
        }

        waitUntil("authenticated route") {
            currentSessionRoute(scenario) is AppSessionRoute.Authenticated
        }

        waitForAttendeeSync(scenario)
    }

    private fun waitForAttendeeSync(scenario: ActivityScenario<MainActivity>) {
        repeat(2) { attempt ->
            scenario.onActivity { activity ->
                viewModel<SyncViewModel>(activity).syncAttendees()
            }

            try {
                waitUntil("attendee sync attempt ${attempt + 1}", timeoutMs = 45_000) {
                    val syncState = currentSyncState(scenario)
                    syncState.bootstrapStatus == BootstrapSyncStatus.Succeeded ||
                        (
                            !syncState.isSyncing &&
                                syncState.errorMessage == null &&
                                syncState.summaryMessage != "No attendee sync has run yet."
                            )
                }
                return
            } catch (_: AssertionError) {
                if (attempt == 1) {
                    throw AssertionError("Attendee sync did not succeed before Play Store capture.")
                }
            }
        }
    }

    private fun selectDestination(
        scenario: ActivityScenario<MainActivity>,
        destination: AppShellDestination
    ) {
        scenario.onActivity { activity ->
            viewModel<AppShellViewModel>(activity).selectDestination(destination)
        }
        waitUntil("destination ${destination.name}") {
            currentSelectedDestination(scenario) == destination
        }
        SystemClock.sleep(750)
        waitForIdle()
    }

    private fun openSupportOverview(scenario: ActivityScenario<MainActivity>) {
        scenario.onActivity { activity ->
            viewModel<AppShellViewModel>(activity)
                .onOverflowActionSelected(AppShellOverflowAction.Support)
        }
        waitUntil("support overview route") {
            currentSupportRoute(scenario) != null
        }
        SystemClock.sleep(750)
        waitForIdle()
    }

    private fun currentSelectedDestination(
        scenario: ActivityScenario<MainActivity>
    ): AppShellDestination {
        var destination: AppShellDestination? = null
        scenario.onActivity { activity ->
            destination = viewModel<AppShellViewModel>(activity).uiState.value.selectedDestination
        }
        return checkNotNull(destination)
    }

    private fun currentSupportRoute(
        scenario: ActivityScenario<MainActivity>
    ): za.co.voelgoed.fastcheck.app.shell.AppShellSupportRoute? {
        var route: za.co.voelgoed.fastcheck.app.shell.AppShellSupportRoute? = null
        scenario.onActivity { activity ->
            route = viewModel<AppShellViewModel>(activity).uiState.value.activeSupportRoute
        }
        return route
    }

    private fun currentSyncState(
        scenario: ActivityScenario<MainActivity>
    ): za.co.voelgoed.fastcheck.feature.sync.SyncScreenUiState {
        var state: za.co.voelgoed.fastcheck.feature.sync.SyncScreenUiState? = null
        scenario.onActivity { activity ->
            state = viewModel<SyncViewModel>(activity).uiState.value
        }
        return checkNotNull(state)
    }

    private fun currentSessionRoute(scenario: ActivityScenario<MainActivity>): AppSessionRoute {
        var route: AppSessionRoute? = null
        scenario.onActivity { activity ->
            route = viewModel<SessionGateViewModel>(activity).route.value
        }
        return checkNotNull(route)
    }

    private fun waitUntil(
        description: String,
        timeoutMs: Long = 30_000,
        predicate: () -> Boolean
    ) {
        val deadline = SystemClock.elapsedRealtime() + timeoutMs
        while (SystemClock.elapsedRealtime() < deadline) {
            waitForIdle()
            if (predicate()) {
                return
            }
            SystemClock.sleep(100)
        }
        throw AssertionError("Timed out waiting for $description.")
    }

    private fun waitForIdle() {
        InstrumentationRegistry.getInstrumentation().waitForIdleSync()
    }

    private inline fun <reified T : ViewModel> viewModel(activity: MainActivity): T =
        ViewModelProvider(activity)[T::class.java]

    private fun requiredStringArg(name: String): String {
        val value = InstrumentationRegistry.getArguments().getString(name)?.trim()
        require(!value.isNullOrBlank()) { "Missing instrumentation argument: $name" }
        return value
    }

    private fun optionalStringArg(name: String): String? =
        InstrumentationRegistry.getArguments().getString(name)?.trim()?.takeIf { it.isNotBlank() }

    private fun requiredLongArg(name: String): Long {
        val value = requiredStringArg(name).toLongOrNull()
        require(value != null && value > 0L) { "Invalid positive long instrumentation argument: $name" }
        return value
    }

    private fun hasRequiredArgs(): Boolean {
        val args = InstrumentationRegistry.getArguments()
        val eventId = args.getString("fastcheck.eventId")?.trim()
        val credential = args.getString("fastcheck.credential")?.trim()
        return !eventId.isNullOrBlank() && !credential.isNullOrBlank()
    }

    private class FakeScannerInputSource : ScannerInputSource {
        override val type: ScannerSourceType = ScannerSourceType.CAMERA
        override val id: String = "play-store-screenshot-camera"

        private val mutableState = MutableStateFlow<ScannerSourceState>(ScannerSourceState.Idle)

        override val state: StateFlow<ScannerSourceState> = mutableState
        override val captures = emptyFlow<ScannerCaptureEvent>()

        override fun start() {
            mutableState.value = ScannerSourceState.Ready
        }

        override fun stop() {
            mutableState.value = ScannerSourceState.Idle
        }
    }
}
