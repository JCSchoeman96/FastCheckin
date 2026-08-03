package za.co.voelgoed.fastcheck.core.session

import android.content.Context
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import dagger.hilt.android.qualifiers.ApplicationContext
import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow

@Singleton
class DefaultAuthenticatedEventContextStore @Inject constructor(
    @ApplicationContext context: Context
) : AuthenticatedEventContextStore {
    private val mutex = Mutex()
    private val preferences = EncryptedSharedPreferences.create(
        context, FILE_NAME,
        MasterKey.Builder(context).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build(),
        EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
        EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
    )
    private val identityState = MutableStateFlow(readValid()?.identity)

    init {
        if (preferences.contains("mobile_jwt")) {
            preferences.edit().remove("mobile_jwt").commit()
        }
    }

    override suspend fun capture(): AuthenticatedEventContext? = mutex.withLock { readValid() }
    override suspend fun currentIdentity(): AuthenticatedEventIdentity? = capture()?.identity

    override suspend fun replace(eventId: Long, bearerToken: String, authenticatedAtEpochMillis: Long, expiresAtEpochMillis: Long): AuthenticatedEventContext = mutex.withLock {
        require(eventId > 0 && bearerToken.isNotBlank() && authenticatedAtEpochMillis >= 0 && expiresAtEpochMillis > authenticatedAtEpochMillis)
        val lastIssued = maxOf(
            preferences.getLong(LAST_GENERATION, 0L),
            preferences.getLong(GENERATION, 0L)
        ).coerceAtLeast(0L)
        check(lastIssued < Long.MAX_VALUE) { "Session generation counter is exhausted" }
        val generation = lastIssued + 1L
        val context = AuthenticatedEventContext(eventId, bearerToken, generation, authenticatedAtEpochMillis, expiresAtEpochMillis)
        check(preferences.edit()
            .putLong(EVENT_ID, eventId).putString(TOKEN, bearerToken).putLong(GENERATION, generation)
            .putLong(AUTHENTICATED_AT, authenticatedAtEpochMillis).putLong(EXPIRES_AT, expiresAtEpochMillis)
            .putLong(LAST_GENERATION, generation).commit())
        identityState.value = context.identity
        context
    }

    override suspend fun clearIfGenerationMatches(sessionGeneration: Long): Boolean = mutex.withLock {
        if (readValid()?.sessionGeneration != sessionGeneration) return@withLock false
        check(preferences.edit().remove(EVENT_ID).remove(TOKEN).remove(GENERATION)
            .remove(AUTHENTICATED_AT).remove(EXPIRES_AT).commit())
        identityState.value = null
        true
    }

    override suspend fun isCurrent(sessionGeneration: Long): Boolean =
        mutex.withLock { readValid()?.sessionGeneration == sessionGeneration }

    override fun observeIdentity(): Flow<AuthenticatedEventIdentity?> = identityState

    private fun readValid(): AuthenticatedEventContext? {
        val eventId = preferences.getLong(EVENT_ID, 0L)
        val token = preferences.getString(TOKEN, null)
        val generation = preferences.getLong(GENERATION, 0L)
        val lastGeneration = preferences.getLong(LAST_GENERATION, 0L)
        val authenticatedAt = preferences.getLong(AUTHENTICATED_AT, -1L)
        val expiresAt = preferences.getLong(EXPIRES_AT, -1L)
        return if (eventId > 0 && !token.isNullOrBlank() && generation > 0 &&
            lastGeneration >= generation && authenticatedAt >= 0 && expiresAt > authenticatedAt
        ) {
            AuthenticatedEventContext(eventId, token, generation, authenticatedAt, expiresAt)
        } else null
    }

    private companion object {
        const val FILE_NAME = "fastcheck-secure-session"
        const val EVENT_ID = "event_id"; const val TOKEN = "bearer_token"; const val GENERATION = "generation"
        const val AUTHENTICATED_AT = "authenticated_at"; const val EXPIRES_AT = "expires_at"; const val LAST_GENERATION = "last_generation"
    }
}
