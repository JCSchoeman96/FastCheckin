package za.co.voelgoed.fastcheck.di

import android.content.Context
import androidx.room.Room
import dagger.Module
import dagger.Provides
import dagger.hilt.android.qualifiers.ApplicationContext
import dagger.hilt.components.SingletonComponent
import dagger.hilt.testing.TestInstallIn
import javax.inject.Singleton
import za.co.voelgoed.fastcheck.app.di.DatabaseModule
import za.co.voelgoed.fastcheck.core.database.FastCheckDatabase
import za.co.voelgoed.fastcheck.data.local.AttendeeLookupDao
import za.co.voelgoed.fastcheck.data.local.EventAttendeeMetricsDao
import za.co.voelgoed.fastcheck.data.local.ScannerDao

@Module
@TestInstallIn(
    components = [SingletonComponent::class],
    replaces = [DatabaseModule::class]
)
object TestDatabaseModule {
    @Provides
    @Singleton
    fun provideDatabase(@ApplicationContext context: Context): FastCheckDatabase =
        Room.inMemoryDatabaseBuilder(context, FastCheckDatabase::class.java)
            .allowMainThreadQueries()
            .build()

    @Provides
    fun provideAttendeeLookupDao(database: FastCheckDatabase): AttendeeLookupDao = database.attendeeLookupDao()

    @Provides
    fun provideEventAttendeeMetricsDao(database: FastCheckDatabase): EventAttendeeMetricsDao =
        database.eventAttendeeMetricsDao()

    @Provides
    fun provideScannerDao(database: FastCheckDatabase): ScannerDao = database.scannerDao()
}
