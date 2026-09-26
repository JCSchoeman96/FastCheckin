package za.co.voelgoed.fastcheck.data.mapper

import com.google.common.truth.Truth.assertThat
import java.time.Clock
import java.time.Instant
import java.time.ZoneOffset
import org.junit.Test
import za.co.voelgoed.fastcheck.data.remote.MobileLoginPayload
import za.co.voelgoed.fastcheck.domain.model.EventAdmissionMode

class SessionMappersTest {
    private val clock = Clock.fixed(Instant.parse("2026-03-13T08:00:00Z"), ZoneOffset.UTC)

    @Test
    fun mapsLoginPayloadIntoSessionAndMetadata() {
        val payload =
            MobileLoginPayload(
                token = "jwt-token",
                event_id = 123,
                event_name = "Voelgoed Live",
                event_shortname = "VG Live",
                expires_in = 3600
            )

        val session = payload.toDomain(clock)
        val metadata = session.toMetadata()

        assertThat(session.eventId).isEqualTo(123)
        assertThat(session.eventName).isEqualTo("Voelgoed Live")
        assertThat(session.eventShortname).isEqualTo("VG Live")
        assertThat(session.authenticatedAtEpochMillis).isEqualTo(1_773_388_800_000)
        assertThat(session.expiresAtEpochMillis).isEqualTo(1_773_392_400_000)
        assertThat(metadata.expiresInSeconds).isEqualTo(3600)
        assertThat(metadata.eventShortname).isEqualTo("VG Live")
        assertThat(metadata.expiresAtEpochMillis).isEqualTo(session.expiresAtEpochMillis)
        assertThat(session.admissionMode).isEqualTo(EventAdmissionMode.SESSION)
        assertThat(metadata.admissionMode).isEqualTo("session")
    }

    @Test
    fun mapsTurnstileAdmissionModeFromLoginIntoSessionAndMetadata() {
        val payload =
            MobileLoginPayload(
                token = "jwt-token",
                event_id = 123,
                event_name = "Voelgoed Live",
                admission_mode = "turnstile",
                expires_in = 3600
            )

        val session = payload.toDomain(clock)
        val metadata = session.toMetadata()

        assertThat(session.admissionMode).isEqualTo(EventAdmissionMode.TURNSTILE)
        assertThat(metadata.admissionMode).isEqualTo("turnstile")
    }
}
