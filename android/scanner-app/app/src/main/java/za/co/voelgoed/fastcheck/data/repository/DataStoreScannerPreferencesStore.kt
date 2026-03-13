package za.co.voelgoed.fastcheck.data.repository

import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.stringPreferencesKey
import kotlinx.coroutines.flow.first
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class DataStoreScannerPreferencesStore @Inject constructor(
    private val dataStore: DataStore<Preferences>
) : ScannerPreferencesStore {
    override suspend fun loadOperatorName(): String? =
        dataStore.data.first()[OPERATOR_NAME]?.takeIf { it.isNotBlank() }

    private companion object {
        val OPERATOR_NAME = stringPreferencesKey("operator_name")
    }
}
