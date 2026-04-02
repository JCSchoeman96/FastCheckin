package za.co.voelgoed.fastcheck.app.session

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import java.time.Clock
import javax.inject.Inject
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import za.co.voelgoed.fastcheck.data.repository.SessionRepository
import za.co.voelgoed.fastcheck.domain.model.ScannerSession

@HiltViewModel
class SessionGateViewModel @Inject constructor(
    private val sessionRepository: SessionRepository,
    private val clock: Clock,
    private val routeResolver: AppSessionRouteResolver
) : ViewModel() {
    private val _route = MutableStateFlow<AppSessionRoute>(AppSessionRoute.RestoringSession)
    val route: StateFlow<AppSessionRoute> = _route.asStateFlow()

    init {
        refreshSessionRoute()
    }

    fun refreshSessionRoute() {
        viewModelScope.launch {
            val session = sessionRepository.currentSession()
            val route = routeResolver.resolve(session, clock.millis())
            when (route) {
                AppSessionRoute.LoggedOut -> {
                    if (session != null) {
                        sessionRepository.logout()
                    }
                    _route.value = AppSessionRoute.LoggedOut
                }
                is AppSessionRoute.Authenticated -> {
                    _route.value = route
                }
                AppSessionRoute.RestoringSession -> {
                    _route.value = AppSessionRoute.RestoringSession
                }
            }
        }
    }

    fun onLoginSucceeded(session: ScannerSession) {
        _route.update { AppSessionRoute.Authenticated(session) }
    }

    fun logout() {
        viewModelScope.launch {
            sessionRepository.logout()
            _route.value = AppSessionRoute.LoggedOut
        }
    }
}
