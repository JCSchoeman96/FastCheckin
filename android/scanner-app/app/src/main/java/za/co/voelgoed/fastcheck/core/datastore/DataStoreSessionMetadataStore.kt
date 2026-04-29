package za.co.voelgoed.fastcheck.core.datastore

import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.intPreferencesKey
import androidx.datastore.preferences.core.longPreferencesKey
import androidx.datastore.preferences.core.stringPreferencesKey
import kotlinx.coroutines.flow.first

class DataStoreSessionMetadataStore(
    private val dataStore: DataStore<Preferences>
) : SessionMetadataStore {
    override suspend fun load(): SessionMetadata? {
        val preferences = dataStore.data.first()
        val eventId = preferences[EVENT_ID] ?: return null
        val eventName = preferences[EVENT_NAME] ?: return null
        val expiresInSeconds = preferences[EXPIRES_IN] ?: return null

        return SessionMetadata(
            eventId = eventId,
            eventName = eventName,
            eventShortname = preferences[EVENT_SHORTNAME].toNullableValue(),
            expiresInSeconds = expiresInSeconds,
            authenticatedAtEpochMillis = preferences[AUTHENTICATED_AT] ?: return null,
            expiresAtEpochMillis = preferences[EXPIRES_AT] ?: return null,
            lastSyncCursor = preferences[LAST_SYNC_CURSOR]
        )
    }

    override suspend fun save(metadata: SessionMetadata) {
        dataStore.edit { preferences ->
            preferences[EVENT_ID] = metadata.eventId
            preferences[EVENT_NAME] = metadata.eventName
            preferences[EVENT_SHORTNAME] = metadata.eventShortname.orEmpty()
            preferences[EXPIRES_IN] = metadata.expiresInSeconds
            preferences[AUTHENTICATED_AT] = metadata.authenticatedAtEpochMillis
            preferences[EXPIRES_AT] = metadata.expiresAtEpochMillis
            preferences[LAST_SYNC_CURSOR] = metadata.lastSyncCursor.orEmpty()
        }
    }

    override suspend fun clear() {
        dataStore.edit { it.clear() }
    }

    private companion object {
        val EVENT_ID = longPreferencesKey("session_event_id")
        val EVENT_NAME = stringPreferencesKey("session_event_name")
        val EVENT_SHORTNAME = stringPreferencesKey("session_event_shortname")
        val EXPIRES_IN = intPreferencesKey("session_expires_in")
        val AUTHENTICATED_AT = longPreferencesKey("session_authenticated_at_epoch_millis")
        val EXPIRES_AT = longPreferencesKey("session_expires_at_epoch_millis")
        val LAST_SYNC_CURSOR = stringPreferencesKey("last_sync_cursor")
    }

    private fun String?.toNullableValue(): String? =
        if (this.isNullOrBlank()) {
            null
        } else {
            this
        }
}
