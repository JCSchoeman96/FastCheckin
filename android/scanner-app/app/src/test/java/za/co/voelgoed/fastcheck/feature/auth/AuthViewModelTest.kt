package za.co.voelgoed.fastcheck.feature.auth

import com.google.common.truth.Truth.assertThat
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Before
import org.junit.Test
import za.co.voelgoed.fastcheck.data.repository.SessionRepository
import za.co.voelgoed.fastcheck.core.session.AuthenticatedEventContext
import za.co.voelgoed.fastcheck.core.session.AuthenticatedEventIdentity
import za.co.voelgoed.fastcheck.domain.model.ScannerSession

@OptIn(ExperimentalCoroutinesApi::class)
class AuthViewModelTest {
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
    fun successfulLoginEmitsOnePayloadFreeCommittedEffect() =
        runTest(dispatcher) {
            val session =
                ScannerSession(
                    eventId = 17L,
                    eventName = "FastCheck Event",
                    expiresInSeconds = 3_600,
                    authenticatedAtEpochMillis = 1_000L,
                    expiresAtEpochMillis = 5_000L
                )
            val repository = RecordingSessionRepository(Result.success(session))
            val viewModel = AuthViewModel(repository)
            val effect = backgroundScope.async(dispatcher) { viewModel.effects.first() }
            runCurrent()

            viewModel.updateEventId("17")
            viewModel.updateCredential("scanner-secret")
            viewModel.login()
            advanceUntilIdle()

            assertThat(effect.await()).isEqualTo(AuthEffect.LoginCommitted)
            assertThat(viewModel.uiState.value.credentialInput).isEmpty()
            assertThat(viewModel.uiState.value.isSubmitting).isFalse()
            assertThat(viewModel.uiState.value.errorMessage).isNull()
        }

    @Test
    fun failedLoginEmitsNoCommittedEffect() =
        runTest(dispatcher) {
            val repository =
                RecordingSessionRepository(Result.failure(IllegalStateException("Login failed.")))
            val viewModel = AuthViewModel(repository)
            val effect = backgroundScope.async(dispatcher) { viewModel.effects.first() }
            runCurrent()

            viewModel.updateEventId("17")
            viewModel.updateCredential("scanner-secret")
            viewModel.login()
            advanceUntilIdle()

            assertThat(effect.isCompleted).isFalse()
            assertThat(viewModel.uiState.value.errorMessage).isEqualTo("Login failed.")
        }

    @Test
    fun authUiStateContainsNoSessionAuthority() {
        val forbiddenTypes =
            setOf(
                ScannerSession::class.java,
                AuthenticatedEventIdentity::class.java,
                AuthenticatedEventContext::class.java
            )

        assertThat(AuthUiState::class.java.declaredFields.map { it.type })
            .containsNoneIn(forbiddenTypes)
    }

    @Test
    fun resetAfterLogoutClearsCredentialsAndPresentation() {
        val viewModel =
            AuthViewModel(
                RecordingSessionRepository(
                    Result.success(
                        ScannerSession(
                            eventId = 18L,
                            eventName = "Event A",
                            expiresInSeconds = 3_600,
                            authenticatedAtEpochMillis = 1_000L,
                            expiresAtEpochMillis = 5_000L
                        )
                    )
                )
            )
        viewModel.updateEventId("19")
        viewModel.updateCredential("test-credential")
        viewModel.setExternalError("Recovery message")

        viewModel.resetAfterLogout()

        assertThat(viewModel.uiState.value).isEqualTo(AuthUiState())
    }

    private class RecordingSessionRepository(
        private val loginResult: Result<ScannerSession>
    ) : SessionRepository {
        override suspend fun login(eventId: Long, credential: String): ScannerSession =
            loginResult.getOrThrow()

        override suspend fun currentSession(): ScannerSession? = null

        override suspend fun logout() = Unit

        override suspend fun onAuthExpired() = Unit

    }
}
