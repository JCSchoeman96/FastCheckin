package za.co.voelgoed.fastcheck.app.di

import android.content.Context
import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.preferencesDataStoreFile
import androidx.datastore.preferences.core.PreferenceDataStoreFactory
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.android.qualifiers.ApplicationContext
import dagger.hilt.components.SingletonComponent
import javax.inject.Singleton
import za.co.voelgoed.fastcheck.core.datastore.DataStoreSessionMetadataStore
import za.co.voelgoed.fastcheck.core.datastore.SessionMetadataStore
import za.co.voelgoed.fastcheck.core.security.EncryptedPrefsSessionVault
import za.co.voelgoed.fastcheck.core.security.SessionVault

@Module
@InstallIn(SingletonComponent::class)
object StorageModule {
    @Provides
    @Singleton
    fun providePreferencesDataStore(@ApplicationContext context: Context): DataStore<Preferences> =
        PreferenceDataStoreFactory.create(
            produceFile = { context.preferencesDataStoreFile("fastcheck-scanner.preferences_pb") }
        )

    @Provides
    @Singleton
    fun provideSessionMetadataStore(
        dataStore: DataStore<Preferences>
    ): SessionMetadataStore = DataStoreSessionMetadataStore(dataStore)

    @Provides
    @Singleton
    fun provideSessionVault(@ApplicationContext context: Context): SessionVault =
        EncryptedPrefsSessionVault(context)
}
