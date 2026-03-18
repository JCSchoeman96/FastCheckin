package za.co.voelgoed.fastcheck.app.di

import dagger.Binds
import dagger.Module
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent
import javax.inject.Singleton
import za.co.voelgoed.fastcheck.core.connectivity.AndroidConnectivityMonitor
import za.co.voelgoed.fastcheck.core.connectivity.ConnectivityMonitor

@Module
@InstallIn(SingletonComponent::class)
abstract class ConnectivityModule {

    @Binds
    @Singleton
    abstract fun bindConnectivityMonitor(
        monitor: AndroidConnectivityMonitor
    ): ConnectivityMonitor
}

