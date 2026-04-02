package za.co.voelgoed.fastcheck.feature.auth

import com.google.common.truth.Truth.assertThat
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Before
import org.junit.Test
import za.co.voelgoed.fastcheck.data.repository.SessionRepository
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
    fun successfulLoginSetsExplicitAuthenticatedSession() =
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

            viewModel.updateEventId("17")
            viewModel.updateCredential("scanner-secret")
            viewModel.login()
            advanceUntilIdle()

            assertThat(viewModel.uiState.value.authenticatedSession).isEqualTo(session)
            assertThat(viewModel.uiState.value.errorMessage).isNull()
        }

    @Test
    fun failedLoginLeavesAuthenticatedSessionNull() =
        runTest(dispatcher) {
            val repository =
                RecordingSessionRepository(Result.failure(IllegalStateException("Login failed.")))
            val viewModel = AuthViewModel(repository)

            viewModel.updateEventId("17")
            viewModel.updateCredential("scanner-secret")
            viewModel.login()
            advanceUntilIdle()

            assertThat(viewModel.uiState.value.authenticatedSession).isNull()
            assertThat(viewModel.uiState.value.errorMessage).isEqualTo("Login failed.")
        }

    private class RecordingSessionRepository(
        private val loginResult: Result<ScannerSession>
    ) : SessionRepository {
        override suspend fun login(eventId: Long, credential: String): ScannerSession =
            loginResult.getOrThrow()

        override suspend fun currentSession(): ScannerSession? = null

        override suspend fun logout() = Unit
    }
}
