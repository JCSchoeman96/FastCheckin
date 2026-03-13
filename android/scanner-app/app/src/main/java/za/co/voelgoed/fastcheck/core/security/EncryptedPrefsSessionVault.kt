package za.co.voelgoed.fastcheck.core.security

import android.content.Context
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey

class EncryptedPrefsSessionVault(
    context: Context
) : SessionVault {
    private val masterKey =
        MasterKey.Builder(context)
            .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
            .build()

    private val preferences =
        EncryptedSharedPreferences.create(
            context,
            FILE_NAME,
            masterKey,
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
        )

    override suspend fun storeToken(token: String) {
        preferences.edit().putString(TOKEN_KEY, token).apply()
    }

    override suspend fun loadToken(): String? = preferences.getString(TOKEN_KEY, null)

    override suspend fun clearToken() {
        preferences.edit().remove(TOKEN_KEY).apply()
    }

    private companion object {
        const val FILE_NAME: String = "fastcheck-secure-session"
        const val TOKEN_KEY: String = "mobile_jwt"
    }
}
