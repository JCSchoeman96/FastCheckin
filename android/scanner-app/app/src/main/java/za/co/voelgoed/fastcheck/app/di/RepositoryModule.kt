package za.co.voelgoed.fastcheck.app.di

import dagger.Binds
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent
import java.time.Clock
import javax.inject.Singleton
import za.co.voelgoed.fastcheck.core.autoflush.AutoFlushCoordinator
import za.co.voelgoed.fastcheck.core.autoflush.ConnectivityProvider
import za.co.voelgoed.fastcheck.core.connectivity.ConnectivityMonitor
import za.co.voelgoed.fastcheck.core.network.SessionProvider
import za.co.voelgoed.fastcheck.core.network.VaultBackedSessionProvider
import za.co.voelgoed.fastcheck.data.repository.CurrentPhoenixMobileScanRepository
import za.co.voelgoed.fastcheck.data.repository.CurrentPhoenixSessionRepository
import za.co.voelgoed.fastcheck.data.repository.CurrentPhoenixSyncRepository
import za.co.voelgoed.fastcheck.data.repository.CurrentSessionAuthGateway
import za.co.voelgoed.fastcheck.data.repository.AttendeeLookupRepository
import za.co.voelgoed.fastcheck.data.repository.CurrentAttendeeLookupRepository
import za.co.voelgoed.fastcheck.data.repository.DataStoreScannerPreferencesStore
import za.co.voelgoed.fastcheck.data.repository.MobileScanRepository
import za.co.voelgoed.fastcheck.data.repository.ScannerPreferencesStore
import za.co.voelgoed.fastcheck.data.repository.SessionAuthGateway
import za.co.voelgoed.fastcheck.data.repository.SessionRepository
import za.co.voelgoed.fastcheck.data.repository.SyncRepository
import za.co.voelgoed.fastcheck.domain.usecase.DefaultFlushQueuedScansUseCase
import za.co.voelgoed.fastcheck.domain.usecase.DefaultQueueCapturedScanUseCase
import za.co.voelgoed.fastcheck.domain.usecase.FlushQueuedScansUseCase
import za.co.voelgoed.fastcheck.domain.usecase.QueueCapturedScanUseCase

@Module
@InstallIn(SingletonComponent::class)
abstract class RepositoryModule {
    @Binds
    @Singleton
    abstract fun bindSessionRepository(
        repository: CurrentPhoenixSessionRepository
    ): SessionRepository

    @Binds
    @Singleton
    abstract fun bindSyncRepository(
        repository: CurrentPhoenixSyncRepository
    ): SyncRepository

    @Binds
    @Singleton
    abstract fun bindMobileScanRepository(
        repository: CurrentPhoenixMobileScanRepository
    ): MobileScanRepository

    @Binds
    @Singleton
    abstract fun bindAttendeeLookupRepository(
        repository: CurrentAttendeeLookupRepository
    ): AttendeeLookupRepository

    @Binds
    @Singleton
    abstract fun bindScannerPreferencesStore(
        store: DataStoreScannerPreferencesStore
    ): ScannerPreferencesStore

    @Binds
    @Singleton
    abstract fun bindSessionAuthGateway(
        gateway: CurrentSessionAuthGateway
    ): SessionAuthGateway

    @Binds
    abstract fun bindQueueCapturedScanUseCase(
        useCase: DefaultQueueCapturedScanUseCase
    ): QueueCapturedScanUseCase

    @Binds
    abstract fun bindFlushQueuedScansUseCase(
        useCase: DefaultFlushQueuedScansUseCase
    ): FlushQueuedScansUseCase

    companion object {
        @Provides
        @Singleton
        fun provideSessionProvider(
            provider: VaultBackedSessionProvider
        ): SessionProvider = provider

        @Provides
        @Singleton
        fun provideClock(): Clock = Clock.systemUTC()

        @Provides
        @Singleton
        fun provideConnectivityProvider(
            connectivityMonitor: ConnectivityMonitor
        ): ConnectivityProvider =
            ConnectivityProvider { connectivityMonitor.isOnline.value }

        @Provides
        @Singleton
        fun provideAutoFlushCoordinator(
            flushQueuedScansUseCase: FlushQueuedScansUseCase,
            mobileScanRepository: MobileScanRepository,
            connectivityProvider: ConnectivityProvider,
            connectivityMonitor: ConnectivityMonitor,
            clock: Clock
        ): AutoFlushCoordinator =
            za.co.voelgoed.fastcheck.core.autoflush.DefaultAutoFlushCoordinator(
                flushQueuedScansUseCase = flushQueuedScansUseCase,
                mobileScanRepository = mobileScanRepository,
                connectivityProvider = connectivityProvider,
                connectivityMonitor = connectivityMonitor,
                clock = clock
            )
    }
}
