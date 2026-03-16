package za.co.voelgoed.fastcheck.data.repository

/**
 * Migration seam that shields runtime code from today's event-scoped JWT login.
 * A future hybrid device/session identity model should replace implementations,
 * not callers.
 */
interface SessionAuthGateway {
    suspend fun currentEventId(): Long?
    suspend fun currentOperatorName(): String?
}
