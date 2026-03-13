package za.co.voelgoed.fastcheck.data.mapper

import za.co.voelgoed.fastcheck.data.local.AttendeeEntity
import za.co.voelgoed.fastcheck.data.remote.AttendeeDto
import za.co.voelgoed.fastcheck.domain.model.AttendeeRecord

fun AttendeeDto.toEntity(): AttendeeEntity =
    AttendeeEntity(
        id = id,
        eventId = event_id,
        ticketCode = ticket_code,
        firstName = first_name,
        lastName = last_name,
        email = email,
        ticketType = ticket_type,
        allowedCheckins = allowed_checkins,
        checkinsRemaining = checkins_remaining,
        paymentStatus = payment_status,
        isCurrentlyInside = is_currently_inside,
        updatedAt = updated_at
    )

fun AttendeeEntity.toDomain(): AttendeeRecord =
    AttendeeRecord(
        id = id,
        eventId = eventId,
        ticketCode = ticketCode,
        fullName = listOfNotNull(firstName, lastName).joinToString(" ").trim(),
        ticketType = ticketType,
        paymentStatus = paymentStatus,
        isCurrentlyInside = isCurrentlyInside,
        updatedAt = updatedAt
    )
