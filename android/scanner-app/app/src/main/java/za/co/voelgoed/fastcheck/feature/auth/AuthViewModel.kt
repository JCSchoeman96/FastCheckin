package za.co.voelgoed.fastcheck.feature.auth

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import javax.inject.Inject
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.launch
import za.co.voelgoed.fastcheck.data.repository.SessionRepository

@HiltViewModel
class AuthViewModel @Inject constructor(
    private val sessionRepository: SessionRepository
) : ViewModel() {
    private val _uiState = MutableStateFlow(AuthUiState())
    val uiState: StateFlow<AuthUiState> = _uiState.asStateFlow()
    private val effectChannel = Channel<AuthEffect>(capacity = Channel.BUFFERED)
    val effects: Flow<AuthEffect> = effectChannel.receiveAsFlow()

    fun updateEventId(value: String) {
        _uiState.update { it.copy(eventIdInput = value, errorMessage = null) }
    }

    fun updateCredential(value: String) {
        _uiState.update { it.copy(credentialInput = value, errorMessage = null) }
    }

    fun setExternalError(message: String?) {
        _uiState.update { it.copy(errorMessage = message) }
    }

    fun login() {
        val eventId = _uiState.value.eventIdInput.toLongOrNull()
        val credential = _uiState.value.credentialInput.trim()

        if (eventId == null || eventId <= 0L) {
            _uiState.update { it.copy(errorMessage = "Event ID must be a positive number.") }
            return
        }

        if (credential.isEmpty()) {
            _uiState.update { it.copy(errorMessage = "Credential is required.") }
            return
        }

        viewModelScope.launch {
            _uiState.update { it.copy(isSubmitting = true, errorMessage = null) }

            runCatching { sessionRepository.login(eventId, credential) }
                .onSuccess {
                    _uiState.update {
                        it.copy(
                            isSubmitting = false,
                            credentialInput = "",
                            errorMessage = null
                        )
                    }
                    effectChannel.send(AuthEffect.LoginCommitted)
                }
                .onFailure { throwable ->
                    _uiState.update {
                        it.copy(
                            isSubmitting = false,
                            errorMessage = throwable.message ?: "Login failed."
                        )
                    }
                }
        }
    }

    fun resetAfterLogout() {
        _uiState.value = AuthUiState()
    }
}
