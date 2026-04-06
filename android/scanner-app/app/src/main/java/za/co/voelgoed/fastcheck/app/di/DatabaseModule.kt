package za.co.voelgoed.fastcheck.app.di

import android.content.Context
import androidx.room.Room
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.android.qualifiers.ApplicationContext
import dagger.hilt.components.SingletonComponent
import javax.inject.Singleton
import za.co.voelgoed.fastcheck.core.database.FastCheckDatabase
import za.co.voelgoed.fastcheck.core.database.FastCheckDatabaseMigrations
import za.co.voelgoed.fastcheck.data.local.AttendeeLookupDao
import za.co.voelgoed.fastcheck.data.local.EventAttendeeMetricsDao
import za.co.voelgoed.fastcheck.data.local.ScannerDao

@Module
@InstallIn(SingletonComponent::class)
object DatabaseModule {
    @Provides
    @Singleton
    fun provideDatabase(@ApplicationContext context: Context): FastCheckDatabase =
        Room.databaseBuilder(
            context,
            FastCheckDatabase::class.java,
            FastCheckDatabase.DATABASE_NAME
        )
            .addMigrations(
                FastCheckDatabaseMigrations.MIGRATION_2_3,
                FastCheckDatabaseMigrations.MIGRATION_3_4,
                FastCheckDatabaseMigrations.MIGRATION_4_5,
                FastCheckDatabaseMigrations.MIGRATION_5_6,
                FastCheckDatabaseMigrations.MIGRATION_6_7,
                FastCheckDatabaseMigrations.MIGRATION_7_8
            )
            .build()

    @Provides
    fun provideAttendeeLookupDao(database: FastCheckDatabase): AttendeeLookupDao = database.attendeeLookupDao()

    @Provides
    fun provideEventAttendeeMetricsDao(database: FastCheckDatabase): EventAttendeeMetricsDao =
        database.eventAttendeeMetricsDao()

    @Provides
    fun provideScannerDao(database: FastCheckDatabase): ScannerDao = database.scannerDao()
}
