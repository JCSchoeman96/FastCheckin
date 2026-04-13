package za.co.voelgoed.fastcheck.app

import android.content.Intent
import android.os.SystemClock
import android.util.Log
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.google.common.truth.Truth.assertThat
import dagger.hilt.android.testing.HiltAndroidRule
import dagger.hilt.android.testing.HiltAndroidTest
import javax.inject.Inject
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import za.co.voelgoed.fastcheck.app.session.AppSessionRoute
import za.co.voelgoed.fastcheck.app.session.SessionGateViewModel
import za.co.voelgoed.fastcheck.core.designsystem.semantic.ScanUiState
import za.co.voelgoed.fastcheck.feature.auth.AuthViewModel
import za.co.voelgoed.fastcheck.feature.scanning.broadcast.DataWedgeScanContract
import za.co.voelgoed.fastcheck.feature.scanning.ui.ScanningViewModel
import za.co.voelgoed.fastcheck.feature.sync.SyncViewModel
import za.co.voelgoed.fastcheck.data.local.ScannerDao
import za.co.voelgoed.fastcheck.data.local.SyncMetadataEntity

@HiltAndroidTest
@RunWith(AndroidJUnit4::class)
class MobileIntegrationHarnessFlowTest {
    @get:Rule
    var hiltRule = HiltAndroidRule(this)

    @Inject
    lateinit var scannerDao: ScannerDao

    @Before
    fun setUp() {
        MainActivityTestHooks.reset()
        assumeTrue(
            "Harness-only test requires fastcheck.eventId, fastcheck.credential, and fastcheck.ticketCode instrumentation args.",
            hasRequiredHarnessArgs()
        )
        hiltRule.inject()
    }

    @After
    fun tearDown() {
        MainActivityTestHooks.reset()
    }

    @Test
    fun activeTicketIsAcceptedAfterLoginAndSync() {
        val eventId = requiredLongArg("fastcheck.eventId")
        val credential = requiredStringArg("fastcheck.credential")
        val ticketCode = requiredStringArg("fastcheck.ticketCode")

        val scenario = launchActivity()
        try {
            loginAndSync(scenario, eventId, credential)

            sendDataWedgeCapture(ticketCode)

            waitUntil("accepted scan outcome") {
                currentSemanticState(scenario) == ScanUiState.AcceptedLocal
            }

            Log.i(LOG_TAG, "checkpoint=accepted eventId=$eventId ticket=$ticketCode")
        } finally {
            scenario.close()
        }
    }

    @Test
    fun mutatedTicketIsRejectedAfterResync() {
        val eventId = requiredLongArg("fastcheck.eventId")
        val credential = requiredStringArg("fastcheck.credential")
        val ticketCode = requiredStringArg("fastcheck.ticketCode")

        val scenario = launchActivity()
        try {
            loginAndSync(scenario, eventId, credential)

            val metadataBeforeMutationSync = runBlocking { scannerDao.loadSyncMetadata(eventId) }

            scenario.onActivity { activity ->
                viewModel<SyncViewModel>(activity).syncAttendees()
            }

            waitForSyncCycleCompletion(scenario, "post-mutation sync cycle")

            val metadataAfterMutationSync = runBlocking { scannerDao.loadSyncMetadata(eventId) }
            val attendeeAfterMutationSync = runBlocking { scannerDao.findAttendee(eventId, ticketCode) }

            assertSyncConvergenceAfterMutation(
                before = metadataBeforeMutationSync,
                after = metadataAfterMutationSync,
                eventId = eventId,
                ticketCode = ticketCode
            )
            assertThat(attendeeAfterMutationSync).isNull()

            sendDataWedgeCapture(ticketCode)

            waitUntil("rejected scan outcome") {
                when (val state = currentSemanticState(scenario)) {
                    is ScanUiState.Invalid,
                    is ScanUiState.ManualReview,
                    is ScanUiState.Failed -> true
                    else -> false
                }
            }

            assertThat(currentSemanticState(scenario)).isNotEqualTo(ScanUiState.AcceptedLocal)
            Log.i(LOG_TAG, "checkpoint=rejected eventId=$eventId ticket=$ticketCode")
        } finally {
            scenario.close()
        }
    }

    private fun launchActivity(): ActivityScenario<MainActivity> =
        ActivityScenario.launch(MainActivity::class.java).also {
            waitForIdle()
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

        scenario.onActivity { activity ->
            viewModel<SyncViewModel>(activity).syncAttendees()
        }

        waitForSyncCycleCompletion(scenario, "initial sync cycle")
    }

    private fun sendDataWedgeCapture(ticketCode: String) {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val intent =
            Intent(DataWedgeScanContract.ACTION_SCAN).apply {
                putExtra(DataWedgeScanContract.EXTRA_DATA_STRING, ticketCode)
            }
        context.sendBroadcast(intent)
    }

    private fun currentSemanticState(scenario: ActivityScenario<MainActivity>): ScanUiState? {
        var state: ScanUiState? = null
        scenario.onActivity { activity ->
            state = viewModel<ScanningViewModel>(activity).uiState.value.captureSemanticState
        }
        return state
    }

    private fun currentSessionRoute(scenario: ActivityScenario<MainActivity>): AppSessionRoute {
        var route: AppSessionRoute? = null
        scenario.onActivity { activity ->
            route = viewModel<SessionGateViewModel>(activity).route.value
        }
        return checkNotNull(route)
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

    private fun waitUntil(
        description: String,
        timeoutMs: Long = 20_000,
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

    private fun waitForSyncCycleCompletion(
        scenario: ActivityScenario<MainActivity>,
        description: String
    ) {
        var sawSyncing = false

        waitUntil(description) {
            val syncState = currentSyncState(scenario)
            if (syncState.isSyncing) {
                sawSyncing = true
            }

            sawSyncing && !syncState.isSyncing && syncState.errorMessage == null
        }

        assertThat(sawSyncing).isTrue()
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

    private fun requiredLongArg(name: String): Long {
        val value = requiredStringArg(name).toLongOrNull()
        require(value != null && value > 0L) { "Invalid positive long instrumentation argument: $name" }
        return value
    }

    private fun hasRequiredHarnessArgs(): Boolean {
        val args = InstrumentationRegistry.getArguments()
        val eventId = args.getString("fastcheck.eventId")?.trim()
        val credential = args.getString("fastcheck.credential")?.trim()
        val ticketCode = args.getString("fastcheck.ticketCode")?.trim()

        return !eventId.isNullOrBlank() && !credential.isNullOrBlank() && !ticketCode.isNullOrBlank()
    }

    private fun assertSyncConvergenceAfterMutation(
        before: SyncMetadataEntity?,
        after: SyncMetadataEntity?,
        eventId: Long,
        ticketCode: String
    ) {
        requireNotNull(after) {
            "Expected sync metadata after mutation for event $eventId ticket $ticketCode."
        }

        val checkpointAdvanced =
            before == null || after.lastInvalidationsCheckpoint > before.lastInvalidationsCheckpoint
        val versionAdvanced =
            before == null || after.lastEventSyncVersion > before.lastEventSyncVersion

        assertThat(checkpointAdvanced || versionAdvanced)
            .isTrue()
    }

    private companion object {
        const val LOG_TAG: String = "MobileHarnessFlowTest"
    }
}
