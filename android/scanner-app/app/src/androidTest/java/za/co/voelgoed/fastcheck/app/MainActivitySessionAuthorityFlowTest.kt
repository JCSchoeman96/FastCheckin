package za.co.voelgoed.fastcheck.app

import android.os.SystemClock
import android.view.View
import android.widget.EditText
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.google.common.truth.Truth.assertThat
import dagger.hilt.android.testing.HiltAndroidRule
import dagger.hilt.android.testing.HiltAndroidTest
import java.io.IOException
import javax.inject.Inject
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import za.co.voelgoed.fastcheck.R
import za.co.voelgoed.fastcheck.app.session.AppSessionRoute
import za.co.voelgoed.fastcheck.app.session.SessionGateViewModel
import za.co.voelgoed.fastcheck.core.session.AuthenticatedEventContextStore
import za.co.voelgoed.fastcheck.data.local.QueuedScanEntity
import za.co.voelgoed.fastcheck.data.local.ScannerDao
import za.co.voelgoed.fastcheck.di.TestSessionRepository
import za.co.voelgoed.fastcheck.feature.queue.QueueViewModel

@HiltAndroidTest
@RunWith(AndroidJUnit4::class)
class MainActivitySessionAuthorityFlowTest {
    @get:Rule(order = 0)
    val hiltRule = HiltAndroidRule(this)

    @get:Rule(order = 1)
    val composeRule = createEmptyComposeRule()

    @Inject
    lateinit var testSessionRepository: TestSessionRepository

    @Inject
    lateinit var scannerDao: ScannerDao

    @Inject
    lateinit var contextStore: AuthenticatedEventContextStore

    @Before
    fun setUp() {
        hiltRule.inject()
        testSessionRepository.reset()
    }

    @After
    fun tearDown() {
        testSessionRepository.reset()
    }

    @Test
    fun logoutThenEventBLoginNeverRestoresEventAShell() {
        val now = System.currentTimeMillis()
        val eventAContext = runBlocking {
            contextStore.replace(
                eventId = 18L,
                bearerToken = "test-event-a-token",
                authenticatedAtEpochMillis = now,
                expiresAtEpochMillis = now + 3_600_000L
            )
        }
        val eventA =
            testSessionRepository.session(
                eventId = 18L,
                eventName = "Event A",
                authenticatedAtEpochMillis = now,
                sessionGeneration = eventAContext.sessionGeneration
            )
        testSessionRepository.setCurrentSession(eventA)
        val queuedScanId = runBlocking {
            scannerDao.insertQueuedScan(
                QueuedScanEntity(
                    eventId = 18L,
                    ticketCode = "SESSION-AUTHORITY-TEST",
                    idempotencyKey = "session-authority-$now",
                    createdAt = now,
                    scannedAt = "2026-08-03T10:00:00Z",
                    entranceName = "Test entrance",
                    operatorName = "Test operator"
                )
            )
        }
        val scenario = ActivityScenario.launch(MainActivity::class.java)

        try {
            waitUntil("Event A authenticated") {
                currentRoute(scenario) == AppSessionRoute.Authenticated(eventA)
            }
            waitUntil("Event A queue visible") {
                queueDepth(scenario) == 1
            }
            testSessionRepository.delayNextLogout()

            composeRule.onNodeWithContentDescription("Open more options").performClick()
            composeRule.onNodeWithText("Logout").performClick()
            composeRule.onNodeWithText("Queued scans still need upload").assertIsDisplayed()
            composeRule.onNodeWithText("Log out").performClick()

            waitUntil("shell hidden for logout") {
                currentRoute(scenario) == AppSessionRoute.LoggingOut &&
                    viewVisibility(scenario, R.id.authenticated_shell_compose_view) == View.GONE &&
                    viewVisibility(scenario, R.id.login_gate_container) == View.VISIBLE &&
                    !isLoginEnabled(scenario)
            }
            scenario.onActivity { activity ->
                activity.findViewById<EditText>(R.id.event_id_input).setText("19")
                activity.findViewById<EditText>(R.id.credential_input).setText("event-b-credential")
                activity.findViewById<View>(R.id.login_button).performClick()
            }
            assertThat(testSessionRepository.loginCallCount).isEqualTo(0)
            assertThat(currentRoute(scenario)).isEqualTo(AppSessionRoute.LoggingOut)

            testSessionRepository.completeLogout()
            waitUntil("logout completed") {
                currentRoute(scenario) == AppSessionRoute.LoggedOut
            }
            assertThat(runBlocking { scannerDao.countPendingScansForEvent(18L) }).isEqualTo(1)

            testSessionRepository.loginFailure = IOException("Event B rejected")
            clickLogin(scenario, eventId = "19", credential = "event-b-credential")
            waitUntil("failed Event B login") { testSessionRepository.loginCallCount == 1 }
            assertThat(currentRoute(scenario)).isEqualTo(AppSessionRoute.LoggedOut)

            testSessionRepository.loginFailure = null
            val eventBContext = runBlocking {
                contextStore.replace(
                    eventId = 19L,
                    bearerToken = "test-event-b-token",
                    authenticatedAtEpochMillis = now + 1_000L,
                    expiresAtEpochMillis = now + 3_601_000L
                )
            }
            testSessionRepository.nextSessionGeneration = eventBContext.sessionGeneration
            clickLogin(scenario, eventId = "19", credential = "event-b-credential")

            waitUntil("Event B repository session rendered") {
                val route = currentRoute(scenario)
                route is AppSessionRoute.Authenticated && route.session.eventId == 19L
            }
            assertThat(runBlocking { scannerDao.countPendingScansForEvent(18L) }).isEqualTo(1)
        } finally {
            scenario.close()
            runBlocking {
                if (queuedScanId > 0L) scannerDao.deleteQueuedScans(listOf(queuedScanId))
                contextStore.capture()?.let { context ->
                    contextStore.clearIfGenerationMatches(context.sessionGeneration)
                }
            }
        }
    }

    private fun clickLogin(
        scenario: ActivityScenario<MainActivity>,
        eventId: String,
        credential: String
    ) {
        scenario.onActivity { activity ->
            activity.findViewById<EditText>(R.id.event_id_input).setText(eventId)
            activity.findViewById<EditText>(R.id.credential_input).setText(credential)
            activity.findViewById<View>(R.id.login_button).performClick()
        }
    }

    private fun currentRoute(scenario: ActivityScenario<MainActivity>): AppSessionRoute {
        var route: AppSessionRoute? = null
        scenario.onActivity { activity ->
            route = viewModel<SessionGateViewModel>(activity).route.value
        }
        return checkNotNull(route)
    }

    private fun viewVisibility(
        scenario: ActivityScenario<MainActivity>,
        viewId: Int
    ): Int {
        var visibility = -1
        scenario.onActivity { activity -> visibility = activity.findViewById<View>(viewId).visibility }
        return visibility
    }

    private fun isLoginEnabled(scenario: ActivityScenario<MainActivity>): Boolean {
        var enabled = false
        scenario.onActivity { activity -> enabled = activity.findViewById<View>(R.id.login_button).isEnabled }
        return enabled
    }

    private fun queueDepth(scenario: ActivityScenario<MainActivity>): Int {
        var depth = -1
        scenario.onActivity { activity -> depth = viewModel<QueueViewModel>(activity).uiState.value.localQueueDepth }
        return depth
    }

    private fun waitUntil(
        description: String,
        timeoutMs: Long = 8_000L,
        predicate: () -> Boolean
    ) {
        val deadline = SystemClock.elapsedRealtime() + timeoutMs
        while (SystemClock.elapsedRealtime() < deadline) {
            InstrumentationRegistry.getInstrumentation().waitForIdleSync()
            if (predicate()) return
            SystemClock.sleep(50L)
        }
        throw AssertionError("Timed out waiting for $description.")
    }

    private inline fun <reified T : ViewModel> viewModel(activity: MainActivity): T =
        ViewModelProvider(activity)[T::class.java]
}
