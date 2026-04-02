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
                noticeMessage = null
            )
        }
    }

    fun onOverflowActionSelected(action: AppShellOverflowAction) {
        val placeholderMessage = action.placeholderMessage ?: return
        _uiState.update { current -> current.copy(noticeMessage = placeholderMessage) }
    }

    fun clearNotice() {
        _uiState.update { current -> current.copy(noticeMessage = null) }
    }

    fun reset() {
        _uiState.value = AppShellUiState()
    }
}
