package za.co.voelgoed.fastcheck.app.session

import za.co.voelgoed.fastcheck.domain.model.ScannerSession

sealed interface AppSessionRoute {
    data object RestoringSession : AppSessionRoute

    data object LoggingOut : AppSessionRoute

    data object LoggedOut : AppSessionRoute

    data class Authenticated(val session: ScannerSession) : AppSessionRoute
}
