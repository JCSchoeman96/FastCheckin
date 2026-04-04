package za.co.voelgoed.fastcheck.app.shell

import androidx.lifecycle.ViewModel
import dagger.hilt.android.lifecycle.HiltViewModel
import javax.inject.Inject
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import za.co.voelgoed.fastcheck.app.navigation.AppShellDestination
import za.co.voelgoed.fastcheck.app.navigation.AppShellOverflowAction

@HiltViewModel
class AppShellViewModel @Inject constructor() : ViewModel() {
    private val _uiState = MutableStateFlow(AppShellUiState())
    val uiState: StateFlow<AppShellUiState> = _uiState.asStateFlow()

    fun selectDestination(destination: AppShellDestination) {
        _uiState.update {
            it.copy(
                selectedDestination = destination,
                activeSupportRoute = null,
                logoutConfirmationQueueDepth = null
            )
        }
    }

    fun onOverflowActionSelected(action: AppShellOverflowAction) {
        when (action) {
            AppShellOverflowAction.Support ->
                _uiState.update { current ->
                    current.copy(
                        activeSupportRoute = AppShellSupportRoute.Overview,
                        logoutConfirmationQueueDepth = null
                    )
                }

            AppShellOverflowAction.Logout -> Unit
        }
    }

    fun openDiagnostics() {
        _uiState.update { current ->
            current.copy(
                activeSupportRoute = AppShellSupportRoute.Diagnostics,
                logoutConfirmationQueueDepth = null
            )
        }
    }

    fun navigateBack() {
        _uiState.update { current ->
            val nextSupportRoute =
                when (current.activeSupportRoute) {
                    AppShellSupportRoute.Diagnostics -> AppShellSupportRoute.Overview
                    AppShellSupportRoute.Overview,
                    null -> null
                }

            current.copy(
                activeSupportRoute = nextSupportRoute,
                logoutConfirmationQueueDepth = null
            )
        }
    }

    fun requestLogout(queueDepth: Int): Boolean {
        if (queueDepth <= 0) {
            _uiState.update { current -> current.copy(logoutConfirmationQueueDepth = null) }
            return false
        }

        _uiState.update { current ->
            current.copy(logoutConfirmationQueueDepth = queueDepth)
        }
        return true
    }

    fun dismissLogoutConfirmation() {
        _uiState.update { current -> current.copy(logoutConfirmationQueueDepth = null) }
    }

    fun reset() {
        _uiState.value = AppShellUiState()
    }
}
