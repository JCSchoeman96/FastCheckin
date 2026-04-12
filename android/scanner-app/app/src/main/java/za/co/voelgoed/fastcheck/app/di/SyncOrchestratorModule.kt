package za.co.voelgoed.fastcheck.app.di

import dagger.Binds
import dagger.Module
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent
import javax.inject.Singleton
import za.co.voelgoed.fastcheck.core.sync.AttendeeSyncBootstrapStateHub
import za.co.voelgoed.fastcheck.core.sync.AttendeeSyncOrchestrator
import za.co.voelgoed.fastcheck.core.sync.DefaultAttendeeSyncOrchestrator
import za.co.voelgoed.fastcheck.domain.policy.AttendeeSyncBootstrapGate

@Module
@InstallIn(SingletonComponent::class)
abstract class SyncOrchestratorModule {
    @Binds
    @Singleton
    abstract fun bindAttendeeSyncOrchestrator(
        impl: DefaultAttendeeSyncOrchestrator
    ): AttendeeSyncOrchestrator

    @Binds
    @Singleton
    abstract fun bindAttendeeSyncBootstrapGate(
        impl: AttendeeSyncBootstrapStateHub
    ): AttendeeSyncBootstrapGate
}
