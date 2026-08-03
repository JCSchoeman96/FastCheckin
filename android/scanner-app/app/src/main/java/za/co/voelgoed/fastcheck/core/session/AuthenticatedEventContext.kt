package za.co.voelgoed.fastcheck.core.session

data class AuthenticatedEventIdentity(val eventId: Long, val sessionGeneration: Long)

data class AuthenticatedEventContext(
    val eventId: Long,
    val bearerToken: String,
    val sessionGeneration: Long,
    val authenticatedAtEpochMillis: Long,
    val expiresAtEpochMillis: Long
) {
    val identity get() = AuthenticatedEventIdentity(eventId, sessionGeneration)
}
