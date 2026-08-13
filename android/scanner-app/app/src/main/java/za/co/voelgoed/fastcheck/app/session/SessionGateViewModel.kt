package za.co.voelgoed.fastcheck.app.session

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import java.time.Clock
import javax.inject.Inject
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import za.co.voelgoed.fastcheck.data.repository.SessionRepository

@HiltViewModel
class SessionGateViewModel @Inject constructor(
    private val sessionRepository: SessionRepository,
    private val clock: Clock,
    private val routeResolver: AppSessionRouteResolver
) : ViewModel() {
    private val _route = MutableStateFlow<AppSessionRoute>(AppSessionRoute.RestoringSession)
    val route: StateFlow<AppSessionRoute> = _route.asStateFlow()

    private val _recoveryMessage = MutableStateFlow<String?>(null)
    val recoveryMessage: StateFlow<String?> = _recoveryMessage.asStateFlow()

    private var requestRevision: Long = 0L
    private var logoutRecoveryRequired: Boolean = false

    init {
        reloadAuthoritativeSession()
    }

    fun reloadAuthoritativeSession() {
        if (_route.value == AppSessionRoute.LoggingOut || logoutRecoveryRequired) return

        val revision = ++requestRevision
        _route.value = AppSessionRoute.RestoringSession
        _recoveryMessage.value = null
        viewModelScope.launch {
            restoreSession(revision)
        }
    }

    fun onLoginCommitted() {
        if (_route.value == AppSessionRoute.LoggingOut) return
        logoutRecoveryRequired = false
        reloadAuthoritativeSession()
    }

    fun logout() {
        if (_route.value == AppSessionRoute.LoggingOut) return

        val revision = ++requestRevision
        _route.value = AppSessionRoute.LoggingOut
        _recoveryMessage.value = null
        viewModelScope.launch {
            runCatching { sessionRepository.logout() }
                .onSuccess {
                    if (revision == requestRevision) {
                        logoutRecoveryRequired = false
                        _route.value = AppSessionRoute.LoggedOut
                    }
                }
                .onFailure {
                    runCatching { sessionRepository.onAuthExpired() }
                    runCatching { sessionRepository.currentSession() }
                    if (revision == requestRevision) {
                        logoutRecoveryRequired = true
                        _route.value = AppSessionRoute.LoggedOut
                        _recoveryMessage.value = LOGOUT_RECOVERY_MESSAGE
                    }
                }
        }
    }

    private suspend fun restoreSession(revision: Long) {
        runCatching { sessionRepository.currentSession() }
            .onSuccess { session ->
                val resolvedRoute = routeResolver.resolve(session, clock.millis())
                when (resolvedRoute) {
                    AppSessionRoute.LoggedOut -> {
                        if (session != null && revision == requestRevision) {
                            session.sessionGeneration?.let { generation ->
                                runCatching {
                                    sessionRepository.expireSession(session.eventId, generation)
                                }
                            }
                        }
                        if (revision == requestRevision) {
                            _route.value = AppSessionRoute.LoggedOut
                        }
                    }
                    is AppSessionRoute.Authenticated -> {
                        if (revision == requestRevision) {
                            _route.value = resolvedRoute
                        }
                    }
                    AppSessionRoute.RestoringSession,
                    AppSessionRoute.LoggingOut -> Unit
                }
            }
            .onFailure {
                if (revision == requestRevision) {
                    _route.value = AppSessionRoute.LoggedOut
                    _recoveryMessage.value = SESSION_RESTORE_RECOVERY_MESSAGE
                }
            }
    }

    private companion object {
        const val LOGOUT_RECOVERY_MESSAGE =
            "Logout could not be completed safely. " +
                "Try again before leaving the device unattended."
        const val SESSION_RESTORE_RECOVERY_MESSAGE =
            "Session could not be restored. Log in again."
    }
}
