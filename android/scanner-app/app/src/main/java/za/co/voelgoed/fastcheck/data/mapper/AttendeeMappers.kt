package za.co.voelgoed.fastcheck.data.mapper

import za.co.voelgoed.fastcheck.data.local.AttendeeEntity
import za.co.voelgoed.fastcheck.data.local.MergedAttendeeLookupProjection
import za.co.voelgoed.fastcheck.data.remote.AttendeeDto
import za.co.voelgoed.fastcheck.domain.model.AttendeeDetailRecord
import za.co.voelgoed.fastcheck.domain.model.AttendeeRecord
import za.co.voelgoed.fastcheck.domain.model.AttendeeSearchRecord

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
        checkedInAt = checked_in_at,
        checkedOutAt = checked_out_at,
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

fun AttendeeEntity.toSearchRecord(): AttendeeSearchRecord =
    AttendeeSearchRecord(
        id = id,
        eventId = eventId,
        ticketCode = ticketCode,
        displayName = displayName(),
        email = email,
        ticketType = ticketType,
        paymentStatus = paymentStatus,
        isCurrentlyInside = isCurrentlyInside,
        allowedCheckins = allowedCheckins,
        checkinsRemaining = checkinsRemaining,
        localOverlayState = null,
        localConflictReasonCode = null,
        localConflictMessage = null
    )

fun AttendeeEntity.toDetailRecord(): AttendeeDetailRecord =
    AttendeeDetailRecord(
        id = id,
        eventId = eventId,
        ticketCode = ticketCode,
        firstName = firstName,
        lastName = lastName,
        displayName = displayName(),
        email = email,
        ticketType = ticketType,
        paymentStatus = paymentStatus,
        isCurrentlyInside = isCurrentlyInside,
        checkedInAt = checkedInAt,
        checkedOutAt = checkedOutAt,
        allowedCheckins = allowedCheckins,
        checkinsRemaining = checkinsRemaining,
        updatedAt = updatedAt,
        localOverlayState = null,
        localConflictReasonCode = null,
        localConflictMessage = null,
        localOverlayScannedAt = null,
        expectedRemainingAfterOverlay = null
    )

fun MergedAttendeeLookupProjection.toSearchRecord(): AttendeeSearchRecord =
    AttendeeSearchRecord(
        id = id,
        eventId = eventId,
        ticketCode = ticketCode,
        displayName = displayName(),
        email = email,
        ticketType = ticketType,
        paymentStatus = paymentStatus,
        isCurrentlyInside = mergedIsCurrentlyInside,
        allowedCheckins = allowedCheckins,
        checkinsRemaining = mergedCheckinsRemaining,
        localOverlayState = activeOverlayState,
        localConflictReasonCode = activeOverlayConflictReasonCode,
        localConflictMessage = activeOverlayConflictMessage
    )

fun MergedAttendeeLookupProjection.toDetailRecord(): AttendeeDetailRecord =
    AttendeeDetailRecord(
        id = id,
        eventId = eventId,
        ticketCode = ticketCode,
        firstName = firstName,
        lastName = lastName,
        displayName = displayName(),
        email = email,
        ticketType = ticketType,
        paymentStatus = paymentStatus,
        isCurrentlyInside = mergedIsCurrentlyInside,
        checkedInAt = mergedCheckedInAt,
        checkedOutAt = mergedCheckedOutAt,
        allowedCheckins = allowedCheckins,
        checkinsRemaining = mergedCheckinsRemaining,
        updatedAt = updatedAt,
        localOverlayState = activeOverlayState,
        localConflictReasonCode = activeOverlayConflictReasonCode,
        localConflictMessage = activeOverlayConflictMessage,
        localOverlayScannedAt = activeOverlayScannedAt,
        expectedRemainingAfterOverlay = expectedRemainingAfterOverlay
    )

private fun AttendeeEntity.displayName(): String =
    listOfNotNull(firstName?.trim().takeUnless { it.isNullOrEmpty() }, lastName?.trim().takeUnless { it.isNullOrEmpty() })
        .joinToString(" ")
        .ifBlank { ticketCode }

private fun MergedAttendeeLookupProjection.displayName(): String =
    listOfNotNull(firstName?.trim().takeUnless { it.isNullOrEmpty() }, lastName?.trim().takeUnless { it.isNullOrEmpty() })
        .joinToString(" ")
        .ifBlank { ticketCode }
