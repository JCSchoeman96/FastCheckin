package za.co.voelgoed.fastcheck.app

import com.google.common.truth.Truth.assertThat
import org.junit.Test
import za.co.voelgoed.fastcheck.domain.model.ScannerSession

class AuthenticatedSessionKeyTest {
    @Test
    fun keyChangesWhenAuthenticatedSessionIdentityChanges() {
        val first =
            AuthenticatedSessionKey.from(
                ScannerSession(
                    eventId = 12,
                    eventName = "Expo",
                    expiresInSeconds = 3600,
                    authenticatedAtEpochMillis = 1_000L,
                    expiresAtEpochMillis = 4_600L
                )
            )
        val second =
            AuthenticatedSessionKey.from(
                ScannerSession(
                    eventId = 12,
                    eventName = "Expo",
                    expiresInSeconds = 3600,
                    authenticatedAtEpochMillis = 2_000L,
                    expiresAtEpochMillis = 5_600L
                )
            )

        assertThat(second).isNotEqualTo(first)
    }

    @Test
    fun keyStaysStableForRepeatedHandlingOfSameAuthenticatedSession() {
        val session =
            ScannerSession(
                eventId = 12,
                eventName = "Expo",
                expiresInSeconds = 3600,
                authenticatedAtEpochMillis = 1_000L,
                expiresAtEpochMillis = 4_600L
            )

        assertThat(AuthenticatedSessionKey.from(session))
            .isEqualTo(AuthenticatedSessionKey.from(session))
    }
}
