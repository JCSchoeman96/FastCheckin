package za.co.voelgoed.fastcheck.data.mapper

import com.google.common.truth.Truth.assertThat
import org.junit.Test
import za.co.voelgoed.fastcheck.data.remote.AttendeeDto

class AttendeeMappersTest {
    @Test
    fun mapsAttendeeDtoToEntityAndDomain() {
        val dto =
            AttendeeDto(
                id = 42,
                event_id = 99,
                ticket_code = "VG-001",
                first_name = "Jane",
                last_name = "Doe",
                email = "jane@example.com",
                ticket_type = "VIP",
                allowed_checkins = 1,
                checkins_remaining = 1,
                payment_status = "completed",
                is_currently_inside = false,
                checked_in_at = null,
                checked_out_at = null,
                updated_at = "2026-03-12T08:00:00Z"
            )

        val entity = dto.toEntity()
        val domain = entity.toDomain()

        assertThat(entity.eventId).isEqualTo(99)
        assertThat(entity.ticketCode).isEqualTo("VG-001")
        assertThat(entity.allowedCheckins).isEqualTo(1)
        assertThat(domain.fullName).isEqualTo("Jane Doe")
        assertThat(domain.ticketCode).isEqualTo("VG-001")
        assertThat(domain.paymentStatus).isEqualTo("completed")
    }
}
