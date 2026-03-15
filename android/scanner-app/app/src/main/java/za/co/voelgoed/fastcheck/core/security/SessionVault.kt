package za.co.voelgoed.fastcheck.core.security

interface SessionVault {
    suspend fun storeToken(token: String)
    suspend fun loadToken(): String?
    suspend fun clearToken()
}
