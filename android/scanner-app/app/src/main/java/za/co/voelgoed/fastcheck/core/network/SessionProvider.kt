package za.co.voelgoed.fastcheck.core.network

/**
 * Access token provider boundary for the current event JWT flow.
 * UI and scanning features should depend on session repositories, not tokens.
 */
interface SessionProvider {
    suspend fun bearerToken(): String?
}
