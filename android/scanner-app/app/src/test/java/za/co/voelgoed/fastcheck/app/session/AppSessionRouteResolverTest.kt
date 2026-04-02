package za.co.voelgoed.fastcheck.app.session

import com.google.common.truth.Truth.assertThat
import org.junit.Test
import za.co.voelgoed.fastcheck.domain.model.ScannerSession

class AppSessionRouteResolverTest {
    private val resolver = AppSessionRouteResolver()

    @Test
    fun nullSessionResolvesToLoggedOut() {
        assertThat(resolver.resolve(session = null, nowEpochMillis = 1_000L))
            .isEqualTo(AppSessionRoute.LoggedOut)
    }

    @Test
    fun expiredSessionResolvesToLoggedOut() {
        val session = testSession(expiresAtEpochMillis = 2_000L)

        assertThat(resolver.resolve(session = session, nowEpochMillis = 2_000L))
            .isEqualTo(AppSessionRoute.LoggedOut)
    }

    @Test
    fun validSessionResolvesToAuthenticated() {
        val session = testSession(expiresAtEpochMillis = 5_000L)

        assertThat(resolver.resolve(session = session, nowEpochMillis = 2_000L))
            .isEqualTo(AppSessionRoute.Authenticated(session))
    }

    private fun testSession(expiresAtEpochMillis: Long) =
        ScannerSession(
            eventId = 42L,
            eventName = "FastCheck Test Event",
            expiresInSeconds = 3_600,
            authenticatedAtEpochMillis = 1_000L,
            expiresAtEpochMillis = expiresAtEpochMillis
        )
}
