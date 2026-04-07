package za.co.voelgoed.fastcheck.data.repository

import za.co.voelgoed.fastcheck.domain.model.ScannerSession

/**
 * Session boundary for the current JWT event login flow.
 * Replace this implementation later for hybrid device/session auth without
 * changing UI or scanning features.
 */
interface SessionRepository {
    suspend fun login(eventId: Long, credential: String): ScannerSession
    suspend fun currentSession(): ScannerSession?
    suspend fun logout()
    suspend fun onAuthExpired()
    suspend fun clearBlockedRestoredSession()
}
