package za.co.voelgoed.fastcheck.data.repository

/**
 * Migration seam that shields runtime code from today's event-scoped JWT login.
 * A future hybrid device/session identity model should replace implementations,
 * not callers.
 */
import za.co.voelgoed.fastcheck.domain.model.EventAdmissionMode

interface SessionAuthGateway {
    suspend fun currentEventId(): Long?
    suspend fun currentOperatorName(): String?
    suspend fun currentAdmissionMode(): EventAdmissionMode
}
