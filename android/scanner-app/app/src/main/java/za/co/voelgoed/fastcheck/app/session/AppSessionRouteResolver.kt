package za.co.voelgoed.fastcheck.app.session

import javax.inject.Inject
import za.co.voelgoed.fastcheck.domain.model.ScannerSession

class AppSessionRouteResolver @Inject constructor() {
    fun resolve(session: ScannerSession?, nowEpochMillis: Long): AppSessionRoute =
        when {
            session == null -> AppSessionRoute.LoggedOut
            session.expiresAtEpochMillis <= nowEpochMillis -> AppSessionRoute.LoggedOut
            else -> AppSessionRoute.Authenticated(session)
        }
}
