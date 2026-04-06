package za.co.voelgoed.fastcheck.app.session

import com.google.common.truth.Truth.assertThat
import java.time.Clock
import java.time.Instant
import java.time.ZoneOffset
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import za.co.voelgoed.fastcheck.core.database.FastCheckDatabase
import za.co.voelgoed.fastcheck.data.repository.UnresolvedAdmissionStateGate
import za.co.voelgoed.fastcheck.data.repository.SessionRepository
import za.co.voelgoed.fastcheck.domain.model.ScannerSession

@OptIn(ExperimentalCoroutinesApi::class)
@RunWith(RobolectricTestRunner::class)
class SessionGateViewModelTest {
    private val clock = Clock.fixed(Instant.parse("2026-04-02T09:00:00Z"), ZoneOffset.UTC)
    private lateinit var unresolvedAdmissionStateGate: UnresolvedAdmissionStateGate

    @Before
    fun setUp() {
        Dispatchers.setMain(kotlinx.coroutines.test.StandardTestDispatcher())
        unresolvedAdmissionStateGate = UnresolvedAdmissionStateGate.fromLoader { emptyList() }
    }

    @After
    fun tearDown() {
        Dispatchers.resetMain()
    }

    @Test
    fun initWithNoSessionRoutesToLoggedOut() =
        runTest {
            val repository = FakeSessionRepository(currentSession = null)

            val viewModel =
                SessionGateViewModel(repository, unresolvedAdmissionStateGate, clock, AppSessionRouteResolver())
            advanceUntilIdle()

            assertThat(viewModel.route.value).isEqualTo(AppSessionRoute.LoggedOut)
            assertThat(repository.logoutCallCount).isEqualTo(0)
        }

    @Test
    fun expiredSessionTriggersCleanupAndRoutesToLoggedOut() =
        runTest {
            val expiredSession = testSession(expiresAtEpochMillis = clock.millis())
            val repository = FakeSessionRepository(currentSession = expiredSession)

            val viewModel =
                SessionGateViewModel(repository, unresolvedAdmissionStateGate, clock, AppSessionRouteResolver())
            advanceUntilIdle()

            assertThat(viewModel.route.value).isEqualTo(AppSessionRoute.LoggedOut)
            assertThat(repository.logoutCallCount).isEqualTo(1)
            assertThat(repository.currentSession).isNull()
        }

    @Test
    fun validSessionRoutesToAuthenticated() =
        runTest {
            val session = testSession(expiresAtEpochMillis = clock.millis() + 60_000L)
            val repository = FakeSessionRepository(currentSession = session)

            val viewModel =
                SessionGateViewModel(repository, unresolvedAdmissionStateGate, clock, AppSessionRouteResolver())
            advanceUntilIdle()

            assertThat(viewModel.route.value).isEqualTo(AppSessionRoute.Authenticated(session))
        }

    @Test
    fun loginSuccessRoutesToAuthenticated() =
        runTest {
            val repository = FakeSessionRepository(currentSession = null)
            val session = testSession(expiresAtEpochMillis = clock.millis() + 60_000L)

            val viewModel =
                SessionGateViewModel(repository, unresolvedAdmissionStateGate, clock, AppSessionRouteResolver())
            advanceUntilIdle()
            viewModel.onLoginSucceeded(session)

            assertThat(viewModel.route.value).isEqualTo(AppSessionRoute.Authenticated(session))
        }

    @Test
    fun logoutClearsSessionAndRoutesToLoggedOut() =
        runTest {
            val repository =
                FakeSessionRepository(
                    currentSession = testSession(expiresAtEpochMillis = clock.millis() + 60_000L)
                )
            val viewModel =
                SessionGateViewModel(repository, unresolvedAdmissionStateGate, clock, AppSessionRouteResolver())
            advanceUntilIdle()

            viewModel.logout()
            advanceUntilIdle()

            assertThat(viewModel.route.value).isEqualTo(AppSessionRoute.LoggedOut)
            assertThat(repository.logoutCallCount).isEqualTo(1)
        }

    @Test
    fun unresolvedOtherEventStateBlocksAuthenticatedRoute() =
        runTest {
            unresolvedAdmissionStateGate = UnresolvedAdmissionStateGate.fromLoader { listOf(99L) }
            val session = testSession(expiresAtEpochMillis = clock.millis() + 60_000L)
            val repository = FakeSessionRepository(currentSession = session)

            val viewModel =
                SessionGateViewModel(repository, unresolvedAdmissionStateGate, clock, AppSessionRouteResolver())
            advanceUntilIdle()

            assertThat(viewModel.route.value).isEqualTo(AppSessionRoute.LoggedOut)
            assertThat(viewModel.blockingMessage.value).contains("event 99")
            assertThat(repository.logoutCallCount).isEqualTo(1)
        }

    private class FakeSessionRepository(
        var currentSession: ScannerSession?
    ) : SessionRepository {
        var logoutCallCount: Int = 0

        override suspend fun login(eventId: Long, credential: String): ScannerSession {
            error("Not used in this test")
        }

        override suspend fun currentSession(): ScannerSession? = currentSession

        override suspend fun logout() {
            logoutCallCount += 1
            currentSession = null
        }
    }

    private fun testSession(expiresAtEpochMillis: Long) =
        ScannerSession(
            eventId = 42L,
            eventName = "FastCheck Test Event",
            expiresInSeconds = 3_600,
            authenticatedAtEpochMillis = clock.millis() - 1_000L,
            expiresAtEpochMillis = expiresAtEpochMillis
        )
}
