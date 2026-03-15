package za.co.voelgoed.fastcheck.core.network

import javax.inject.Inject
import javax.inject.Singleton
import za.co.voelgoed.fastcheck.core.security.SessionVault

@Singleton
class VaultBackedSessionProvider @Inject constructor(
    private val sessionVault: SessionVault
) : SessionProvider {
    override suspend fun bearerToken(): String? = sessionVault.loadToken()
}
