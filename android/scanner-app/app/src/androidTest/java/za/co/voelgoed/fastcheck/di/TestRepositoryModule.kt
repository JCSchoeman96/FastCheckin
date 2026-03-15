package za.co.voelgoed.fastcheck.di

import dagger.Module
import dagger.Provides
import dagger.hilt.components.SingletonComponent
import dagger.hilt.testing.TestInstallIn
import java.time.Clock
import java.time.Instant
import java.time.ZoneOffset
import javax.inject.Singleton
import za.co.voelgoed.fastcheck.app.di.RepositoryModule
import za.co.voelgoed.fastcheck.core.network.SessionProvider
import za.co.voelgoed.fastcheck.data.repository.MobileScanRepository
import za.co.voelgoed.fastcheck.data.repository.ScannerPreferencesStore
import za.co.voelgoed.fastcheck.data.repository.SessionAuthGateway
import za.co.voelgoed.fastcheck.data.repository.SessionRepository
import za.co.voelgoed.fastcheck.data.repository.SyncRepository
import za.co.voelgoed.fastcheck.domain.model.AttendeeSyncStatus
import za.co.voelgoed.fastcheck.domain.model.FlushExecutionStatus
import za.co.voelgoed.fastcheck.domain.model.FlushReport
import za.co.voelgoed.fastcheck.domain.model.PendingScan
import za.co.voelgoed.fastcheck.domain.model.QueueCreationResult
import za.co.voelgoed.fastcheck.domain.model.ScannerSession
import za.co.voelgoed.fastcheck.domain.usecase.FlushQueuedScansUseCase
import za.co.voelgoed.fastcheck.domain.usecase.QueueCapturedScanUseCase

@Module
@TestInstallIn(
    components = [SingletonComponent::class],
    replaces = [RepositoryModule::class]
)
object TestRepositoryModule {
    @Provides
    @Singleton
    fun provideClock(): Clock = Clock.fixed(Instant.parse("2026-03-12T10:00:00Z"), ZoneOffset.UTC)

    @Provides
    @Singleton
    fun provideSessionRepository(): SessionRepository =
        object : SessionRepository {
            override suspend fun login(eventId: Long, credential: String): ScannerSession =
                ScannerSession(
                    eventId = eventId,
                    eventName = "Test Event",
                    expiresInSeconds = 3600,
                    authenticatedAtEpochMillis = 1_700_000_000_000,
                    expiresAtEpochMillis = 1_700_003_600_000
                )

            override suspend fun currentSession(): ScannerSession =
                ScannerSession(
                    eventId = 5,
                    eventName = "Test Event",
                    expiresInSeconds = 3600,
                    authenticatedAtEpochMillis = 1_700_000_000_000,
                    expiresAtEpochMillis = 1_700_003_600_000
                )

            override suspend fun logout() = Unit
        }

    @Provides
    @Singleton
    fun provideSessionProvider(): SessionProvider =
        object : SessionProvider {
            override suspend fun bearerToken(): String = "test-token"
        }

    @Provides
    @Singleton
    fun provideSyncRepository(): SyncRepository =
        object : SyncRepository {
            override suspend fun syncAttendees(): AttendeeSyncStatus? = null
            override suspend fun currentSyncStatus(): AttendeeSyncStatus? = null
        }

    @Provides
    @Singleton
    fun provideMobileScanRepository(): MobileScanRepository =
        object : MobileScanRepository {
            override suspend fun queueScan(scan: PendingScan): QueueCreationResult =
                QueueCreationResult.Enqueued(scan)

            override suspend fun flushQueuedScans(maxBatchSize: Int): FlushReport =
                FlushReport(executionStatus = FlushExecutionStatus.COMPLETED, uploadedCount = 0)

            override suspend fun pendingQueueDepth(): Int = 0

            override suspend fun latestFlushReport(): FlushReport? = null
        }

    @Provides
    @Singleton
    fun provideScannerPreferencesStore(): ScannerPreferencesStore =
        object : ScannerPreferencesStore {
            override suspend fun loadOperatorName(): String = "Test Operator"
        }

    @Provides
    @Singleton
    fun provideSessionAuthGateway(): SessionAuthGateway =
        object : SessionAuthGateway {
            override suspend fun currentEventId(): Long = 5
            override suspend fun currentOperatorName(): String = "Test Operator"
        }

    @Provides
    @Singleton
    fun provideQueueCapturedScanUseCase(): QueueCapturedScanUseCase =
        object : QueueCapturedScanUseCase {
            override suspend fun enqueue(
                ticketCode: String,
                direction: za.co.voelgoed.fastcheck.domain.model.ScanDirection,
                operatorName: String,
                entranceName: String
            ): QueueCreationResult = QueueCreationResult.InvalidTicketCode
        }

    @Provides
    @Singleton
    fun provideFlushQueuedScansUseCase(): FlushQueuedScansUseCase =
        object : FlushQueuedScansUseCase {
            override suspend fun run(maxBatchSize: Int): FlushReport =
                FlushReport(executionStatus = FlushExecutionStatus.COMPLETED)
        }
}
