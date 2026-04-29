package za.co.voelgoed.fastcheck.data.mapper

import java.time.Clock
import java.time.Instant
import za.co.voelgoed.fastcheck.core.datastore.SessionMetadata
import za.co.voelgoed.fastcheck.data.remote.MobileLoginPayload
import za.co.voelgoed.fastcheck.domain.model.ScannerSession

fun MobileLoginPayload.toDomain(clock: Clock): ScannerSession {
    val authenticatedAt = Instant.now(clock)
    val expiresAt = authenticatedAt.plusSeconds(expires_in.toLong())

    return ScannerSession(
        eventId = event_id,
        eventName = event_name,
        eventShortname = event_shortname.toNullableValue(),
        expiresInSeconds = expires_in,
        authenticatedAtEpochMillis = authenticatedAt.toEpochMilli(),
        expiresAtEpochMillis = expiresAt.toEpochMilli()
    )
}

fun ScannerSession.toMetadata(): SessionMetadata =
    SessionMetadata(
        eventId = eventId,
        eventName = eventName,
        eventShortname = eventShortname,
        expiresInSeconds = expiresInSeconds,
        authenticatedAtEpochMillis = authenticatedAtEpochMillis,
        expiresAtEpochMillis = expiresAtEpochMillis
    )

fun SessionMetadata.toDomain(): ScannerSession =
    ScannerSession(
        eventId = eventId,
        eventName = eventName,
        eventShortname = eventShortname,
        expiresInSeconds = expiresInSeconds,
        authenticatedAtEpochMillis = authenticatedAtEpochMillis,
        expiresAtEpochMillis = expiresAtEpochMillis
    )

private fun String?.toNullableValue(): String? =
    if (this.isNullOrBlank()) {
        null
    } else {
        this
    }
