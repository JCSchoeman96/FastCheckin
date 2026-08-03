package za.co.voelgoed.fastcheck.core.session

import kotlinx.coroutines.flow.Flow

interface AuthenticatedEventContextStore {
    suspend fun capture(): AuthenticatedEventContext?
    suspend fun currentIdentity(): AuthenticatedEventIdentity?
    suspend fun replace(eventId: Long, bearerToken: String, authenticatedAtEpochMillis: Long, expiresAtEpochMillis: Long): AuthenticatedEventContext
    suspend fun clearIfGenerationMatches(sessionGeneration: Long): Boolean
    suspend fun isCurrent(sessionGeneration: Long): Boolean
    fun observeIdentity(): Flow<AuthenticatedEventIdentity?>
}
