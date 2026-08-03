package za.co.voelgoed.fastcheck.app.session

import com.google.common.truth.Truth.assertThat
import java.io.IOException
import java.time.Clock
import java.time.Instant
import java.time.ZoneOffset
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import za.co.voelgoed.fastcheck.data.repository.SessionRepository
import za.co.voelgoed.fastcheck.domain.model.ScannerSession

@OptIn(ExperimentalCoroutinesApi::class)
@RunWith(RobolectricTestRunner::class)
class SessionGateViewModelTest {
    private val clock = Clock.fixed(Instant.parse("2026-04-02T09:00:00Z"), ZoneOffset.UTC)
    private val dispatcher = StandardTestDispatcher()

    @Before
    fun setUp() {
        Dispatchers.setMain(dispatcher)
    }

    @After
    fun tearDown() {
        Dispatchers.resetMain()
    }

    @Test
    fun initWithNoSessionRoutesToLoggedOut() =
        runTest(dispatcher) {
            val repository = FakeSessionRepository(currentSessionValue = null)

            val viewModel = SessionGateViewModel(repository, clock, AppSessionRouteResolver())
            advanceUntilIdle()

            assertThat(viewModel.route.value).isEqualTo(AppSessionRoute.LoggedOut)
            assertThat(repository.logoutCallCount).isEqualTo(0)
        }

    @Test
    fun expiredSessionTriggersCleanupAndRoutesToLoggedOut() =
        runTest(dispatcher) {
            val expiredSession =
                testSession(expiresAtEpochMillis = clock.millis(), sessionGeneration = 7L)
            val repository = FakeSessionRepository(currentSessionValue = expiredSession)

            val viewModel = SessionGateViewModel(repository, clock, AppSessionRouteResolver())
            advanceUntilIdle()

            assertThat(viewModel.route.value).isEqualTo(AppSessionRoute.LoggedOut)
            assertThat(repository.expiredSessionIdentities).containsExactly(42L to 7L)
            assertThat(repository.authExpiredCallCount).isEqualTo(0)
            assertThat(repository.currentSessionValue).isNull()
        }

    @Test
    fun reloadUsesRepositoryEventInsteadOfCallerState() =
        runTest(dispatcher) {
            val eventB = testSession(eventId = 19L)
            val repository = FakeSessionRepository(currentSessionValue = eventB)

            val viewModel = SessionGateViewModel(repository, clock, AppSessionRouteResolver())
            advanceUntilIdle()

            assertThat(viewModel.route.value).isEqualTo(AppSessionRoute.Authenticated(eventB))
        }

    @Test
    fun reloadSynchronouslyHidesShellWhileRepositoryReadIsDelayed() =
        runTest(dispatcher) {
            val eventA = testSession(eventId = 18L)
            val repository = FakeSessionRepository(currentSessionValue = eventA)
            val viewModel = SessionGateViewModel(repository, clock, AppSessionRouteResolver())
            advanceUntilIdle()
            val scriptedRead = repository.delayNextCurrentSessionAfterCapture()

            viewModel.reloadAuthoritativeSession()

            assertThat(viewModel.route.value).isEqualTo(AppSessionRoute.RestoringSession)
            runCurrent()
            scriptedRead.captured.await()
            assertThat(viewModel.route.value).isEqualTo(AppSessionRoute.RestoringSession)
            scriptedRead.release.complete(Unit)
            advanceUntilIdle()
            assertThat(viewModel.route.value).isEqualTo(AppSessionRoute.Authenticated(eventA))
        }

    @Test
    fun logoutHidesAuthenticatedRouteBeforeRepositoryFinishes() =
        runTest(dispatcher) {
            val logoutRelease = CompletableDeferred<Unit>()
            val repository =
                FakeSessionRepository(
                    currentSessionValue = testSession(),
                    logoutRelease = logoutRelease
                )
            val viewModel = SessionGateViewModel(repository, clock, AppSessionRouteResolver())
            advanceUntilIdle()

            viewModel.logout()

            assertThat(viewModel.route.value).isEqualTo(AppSessionRoute.LoggingOut)
            runCurrent()
            logoutRelease.complete(Unit)
            advanceUntilIdle()
            assertThat(viewModel.route.value).isEqualTo(AppSessionRoute.LoggedOut)
        }

    @Test
    fun staleReloadCannotOverwriteNewerLogout() =
        runTest(dispatcher) {
            val eventA = testSession(eventId = 18L)
            val repository = FakeSessionRepository(currentSessionValue = eventA)
            val viewModel = SessionGateViewModel(repository, clock, AppSessionRouteResolver())
            advanceUntilIdle()
            val scriptedRead = repository.delayNextCurrentSessionAfterCapture()

            viewModel.reloadAuthoritativeSession()
            runCurrent()
            scriptedRead.captured.await()
            viewModel.logout()
            runCurrent()
            assertThat(viewModel.route.value).isEqualTo(AppSessionRoute.LoggedOut)

            scriptedRead.release.complete(Unit)
            advanceUntilIdle()

            assertThat(viewModel.route.value).isEqualTo(AppSessionRoute.LoggedOut)
        }

    @Test
    fun logoutFailureRemainsLoggedOutAndSuppressesAutomaticRestore() =
        runTest(dispatcher) {
            val eventA = testSession(eventId = 18L)
            val repository =
                FakeSessionRepository(
                    currentSessionValue = eventA,
                    logoutFailure = IOException("logout failed"),
                    authExpiredFailure = IOException("expiry cleanup failed")
                )
            val viewModel = SessionGateViewModel(repository, clock, AppSessionRouteResolver())
            advanceUntilIdle()

            viewModel.logout()
            advanceUntilIdle()

            assertThat(viewModel.route.value).isEqualTo(AppSessionRoute.LoggedOut)
            assertThat(viewModel.recoveryMessage.value)
                .isEqualTo(
                    "Logout could not be completed safely. " +
                        "Try again before leaving the device unattended."
                )
            assertThat(repository.authExpiredCallCount).isEqualTo(1)
            val readsAfterRecovery = repository.currentSessionCallCount

            viewModel.reloadAuthoritativeSession()
            advanceUntilIdle()

            assertThat(viewModel.route.value).isEqualTo(AppSessionRoute.LoggedOut)
            assertThat(repository.currentSessionCallCount).isEqualTo(readsAfterRecovery)
        }

    @Test
    fun successfulLoginCommittedReplacesUnresolvedLogoutContextWithRepositoryEvent() =
        runTest(dispatcher) {
            val repository =
                FakeSessionRepository(
                    currentSessionValue = testSession(eventId = 18L),
                    logoutFailure = IOException("logout failed"),
                    authExpiredFailure = IOException("expiry cleanup failed")
                )
            val viewModel = SessionGateViewModel(repository, clock, AppSessionRouteResolver())
            advanceUntilIdle()
            viewModel.logout()
            advanceUntilIdle()
            val eventB = testSession(eventId = 19L)
            repository.currentSessionValue = eventB

            viewModel.onLoginCommitted()
            assertThat(viewModel.route.value).isEqualTo(AppSessionRoute.RestoringSession)
            advanceUntilIdle()

            assertThat(viewModel.route.value).isEqualTo(AppSessionRoute.Authenticated(eventB))
        }

    @Test
    fun staleExpiredReloadCannotClearNewerAuthenticatedSession() =
        runTest(dispatcher) {
            val eventA =
                testSession(
                    eventId = 18L,
                    expiresAtEpochMillis = clock.millis(),
                    sessionGeneration = 10L
                )
            val eventB = testSession(eventId = 19L, sessionGeneration = 20L)
            val repository = FakeSessionRepository(currentSessionValue = eventA)
            val staleEventARead = repository.delayNextCurrentSessionAfterCapture()
            val viewModel = SessionGateViewModel(repository, clock, AppSessionRouteResolver())
            runCurrent()
            staleEventARead.captured.await()
            repository.currentSessionValue = eventB

            viewModel.onLoginCommitted()
            runCurrent()

            assertThat(viewModel.route.value).isEqualTo(AppSessionRoute.Authenticated(eventB))
            staleEventARead.release.complete(Unit)
            advanceUntilIdle()

            assertThat(repository.currentSessionValue).isEqualTo(eventB)
            assertThat(viewModel.route.value).isEqualTo(AppSessionRoute.Authenticated(eventB))
            assertThat(repository.authExpiredCallCount).isEqualTo(0)
            assertThat(repository.expiredSessionIdentities).isEmpty()
        }

    @Test
    fun identityConditionalExpiryCannotClearLoginCommittedDuringCleanup() =
        runTest(dispatcher) {
            val eventA =
                testSession(
                    eventId = 18L,
                    expiresAtEpochMillis = clock.millis(),
                    sessionGeneration = 10L
                )
            val eventB = testSession(eventId = 19L, sessionGeneration = 20L)
            val repository = FakeSessionRepository(currentSessionValue = eventA)
            val delayedExpiry = repository.delayNextExpireSession()
            val viewModel = SessionGateViewModel(repository, clock, AppSessionRouteResolver())
            runCurrent()
            delayedExpiry.captured.await()
            repository.currentSessionValue = eventB

            viewModel.onLoginCommitted()
            runCurrent()

            assertThat(viewModel.route.value).isEqualTo(AppSessionRoute.Authenticated(eventB))
            delayedExpiry.release.complete(Unit)
            advanceUntilIdle()

            assertThat(repository.expiredSessionIdentities).containsExactly(18L to 10L)
            assertThat(repository.currentSessionValue).isEqualTo(eventB)
            assertThat(viewModel.route.value).isEqualTo(AppSessionRoute.Authenticated(eventB))
            assertThat(repository.authExpiredCallCount).isEqualTo(0)
        }

    @Test
    fun noPublicGateMethodAcceptsCallerProvidedSession() {
        val methodsAcceptingSession =
            SessionGateViewModel::class.java.methods.filter { method ->
                method.parameterTypes.contains(ScannerSession::class.java)
            }

        assertThat(methodsAcceptingSession).isEmpty()
    }

    private class FakeSessionRepository(
        var currentSessionValue: ScannerSession?,
        private val logoutRelease: CompletableDeferred<Unit>? = null,
        private val logoutFailure: Throwable? = null,
        private val authExpiredFailure: Throwable? = null
    ) : SessionRepository {
        var logoutCallCount: Int = 0
        var authExpiredCallCount: Int = 0
        val expiredSessionIdentities = mutableListOf<Pair<Long, Long>>()
        var currentSessionCallCount: Int = 0
        private var nextCurrentSessionScript: ScriptedRead? = null
        private var nextExpireSessionScript: ScriptedRead? = null

        override suspend fun login(eventId: Long, credential: String): ScannerSession {
            error("Not used in this test")
        }

        override suspend fun currentSession(): ScannerSession? {
            currentSessionCallCount += 1
            val script = nextCurrentSessionScript
            if (script != null) {
                nextCurrentSessionScript = null
                val capturedSession = currentSessionValue
                script.captured.complete(Unit)
                script.release.await()
                return capturedSession
            }
            return currentSessionValue
        }

        override suspend fun logout() {
            logoutCallCount += 1
            logoutRelease?.await()
            logoutFailure?.let { throw it }
            currentSessionValue = null
        }

        override suspend fun onAuthExpired() {
            authExpiredCallCount += 1
            authExpiredFailure?.let { throw it }
            currentSessionValue = null
        }

        override suspend fun expireSession(eventId: Long, sessionGeneration: Long) {
            expiredSessionIdentities += eventId to sessionGeneration
            nextExpireSessionScript?.also { script ->
                nextExpireSessionScript = null
                script.captured.complete(Unit)
                script.release.await()
            }
            if (
                currentSessionValue?.eventId == eventId &&
                currentSessionValue?.sessionGeneration == sessionGeneration
            ) {
                currentSessionValue = null
            }
        }

        fun delayNextCurrentSessionAfterCapture(): ScriptedRead =
            ScriptedRead().also { nextCurrentSessionScript = it }

        fun delayNextExpireSession(): ScriptedRead =
            ScriptedRead().also { nextExpireSessionScript = it }
    }

    private class ScriptedRead(
        val captured: CompletableDeferred<Unit> = CompletableDeferred(),
        val release: CompletableDeferred<Unit> = CompletableDeferred()
    )

    private fun testSession(
        eventId: Long = 42L,
        expiresAtEpochMillis: Long = clock.millis() + 60_000L,
        sessionGeneration: Long? = null
    ) = ScannerSession(
        eventId = eventId,
        eventName = "FastCheck Test Event $eventId",
        expiresInSeconds = 3_600,
        authenticatedAtEpochMillis = clock.millis() - 1_000L,
        expiresAtEpochMillis = expiresAtEpochMillis,
        sessionGeneration = sessionGeneration
    )
}
