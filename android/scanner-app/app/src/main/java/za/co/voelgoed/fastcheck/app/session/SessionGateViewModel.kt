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
    private val unresolvedAdmissionStateGate: za.co.voelgoed.fastcheck.data.repository.UnresolvedAdmissionStateGate,
    private val clock: Clock,
    private val routeResolver: AppSessionRouteResolver
) : ViewModel() {
    private val _route = MutableStateFlow<AppSessionRoute>(AppSessionRoute.RestoringSession)
    val route: StateFlow<AppSessionRoute> = _route.asStateFlow()
    private val _blockingMessage = MutableStateFlow<String?>(null)
    val blockingMessage: StateFlow<String?> = _blockingMessage.asStateFlow()

    init {
        refreshSessionRoute()
    }

    fun refreshSessionRoute() {
        viewModelScope.launch {
            val session = sessionRepository.currentSession()
            if (session != null) {
                val unresolvedOtherEvents =
                    unresolvedAdmissionStateGate.unresolvedOtherEventIds(session.eventId)

                if (unresolvedOtherEvents.isNotEmpty()) {
                    sessionRepository.logout()
                    _blockingMessage.value =
                        CrossEventBlockingMessageFormatter.format(
                            targetEventId = session.eventId,
                            unresolvedEventIds = unresolvedOtherEvents
                        )
                    _route.value = AppSessionRoute.LoggedOut
                    return@launch
                }
            }

            val route = routeResolver.resolve(session, clock.millis())
            when (route) {
                AppSessionRoute.LoggedOut -> {
                    if (session != null) {
                        sessionRepository.logout()
                    }
                    _blockingMessage.value = null
                    _route.value = AppSessionRoute.LoggedOut
                }
                is AppSessionRoute.Authenticated -> {
                    _blockingMessage.value = null
                    _route.value = route
                }
                AppSessionRoute.RestoringSession -> {
                    _route.value = AppSessionRoute.RestoringSession
                }
            }
        }
    }

    fun onLoginSucceeded(session: ScannerSession) {
        _blockingMessage.value = null
        _route.update { AppSessionRoute.Authenticated(session) }
    }

    fun logout() {
        viewModelScope.launch {
            sessionRepository.logout()
            _blockingMessage.value = null
            _route.value = AppSessionRoute.LoggedOut
        }
    }
}

private object CrossEventBlockingMessageFormatter {
    fun format(
        targetEventId: Long,
        unresolvedEventIds: List<Long>
    ): String =
        buildString {
            append("Unresolved local gate state exists for ")
            append(unresolvedEventIds.joinToString(prefix = "event ", separator = ", event "))
            append(". Resolve that event before opening event #")
            append(targetEventId)
            append(".")
        }
}
