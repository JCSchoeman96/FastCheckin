package za.co.voelgoed.fastcheck.di

import dagger.Module
import dagger.Provides
import dagger.hilt.components.SingletonComponent
import dagger.hilt.testing.TestInstallIn
import androidx.test.platform.app.InstrumentationRegistry
import java.time.Clock
import java.time.Instant
import java.time.ZoneOffset
import javax.inject.Singleton
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.flowOf
import za.co.voelgoed.fastcheck.app.di.RepositoryModule
import za.co.voelgoed.fastcheck.core.autoflush.AutoFlushCoordinator
import za.co.voelgoed.fastcheck.core.autoflush.AutoFlushCoordinatorState
import za.co.voelgoed.fastcheck.core.autoflush.AutoFlushTrigger
import za.co.voelgoed.fastcheck.core.concurrency.DefaultEventOperationMutexRegistry
import za.co.voelgoed.fastcheck.core.concurrency.EventOperationMutexRegistry
import za.co.voelgoed.fastcheck.core.session.AuthenticatedEventContextStore
import za.co.voelgoed.fastcheck.core.session.DefaultAuthenticatedEventContextStore
import za.co.voelgoed.fastcheck.data.repository.CurrentAttendeeLookupRepository
import za.co.voelgoed.fastcheck.data.repository.CurrentPhoenixMobileScanRepository
import za.co.voelgoed.fastcheck.data.repository.CurrentPhoenixSessionRepository
import za.co.voelgoed.fastcheck.data.repository.CurrentPhoenixSyncRepository
import za.co.voelgoed.fastcheck.data.repository.CurrentSessionAuthGateway
import za.co.voelgoed.fastcheck.data.repository.DefaultEventBucketRepository
import za.co.voelgoed.fastcheck.data.repository.EventBucketRepository
import za.co.voelgoed.fastcheck.data.repository.MobileScanRepository
import za.co.voelgoed.fastcheck.data.repository.AttendeeLookupRepository
import za.co.voelgoed.fastcheck.data.repository.EventAttendeeMetricsRepository
import za.co.voelgoed.fastcheck.data.repository.ScannerPreferencesStore
import za.co.voelgoed.fastcheck.data.repository.SessionAuthGateway
import za.co.voelgoed.fastcheck.data.repository.SessionRepository
import za.co.voelgoed.fastcheck.data.repository.AttendeeSyncMode
import za.co.voelgoed.fastcheck.data.repository.SyncRepository
import za.co.voelgoed.fastcheck.domain.model.AttendeeSyncStatus
import za.co.voelgoed.fastcheck.domain.model.AttendeeDetailRecord
import za.co.voelgoed.fastcheck.domain.model.AttendeeSearchRecord
import za.co.voelgoed.fastcheck.domain.model.EventAttendeeCacheMetrics
import za.co.voelgoed.fastcheck.domain.model.FlushExecutionStatus
import za.co.voelgoed.fastcheck.domain.model.FlushReport
import za.co.voelgoed.fastcheck.domain.model.LocalAdmissionDecision
import za.co.voelgoed.fastcheck.domain.model.LocalAdmissionRejectReason
import za.co.voelgoed.fastcheck.domain.model.PendingScan
import za.co.voelgoed.fastcheck.domain.model.QueueCreationResult
import za.co.voelgoed.fastcheck.domain.model.QuarantineSummary
import za.co.voelgoed.fastcheck.domain.model.ScanDirection
import za.co.voelgoed.fastcheck.domain.model.ScannerSession
import za.co.voelgoed.fastcheck.domain.usecase.AdmitScanUseCase
import za.co.voelgoed.fastcheck.domain.usecase.DefaultAdmitScanUseCase
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
    fun provideAuthenticatedEventContextStore(
        store: DefaultAuthenticatedEventContextStore
    ): AuthenticatedEventContextStore = store

    @Provides
    @Singleton
    fun provideEventBucketRepository(
        repository: DefaultEventBucketRepository
    ): EventBucketRepository = repository

    @Provides
    @Singleton
    fun provideEventOperationMutexRegistry(
        registry: DefaultEventOperationMutexRegistry
    ): EventOperationMutexRegistry = registry

    @Provides
    @Singleton
    fun provideTestSessionRepository(): TestSessionRepository = TestSessionRepository()

    @Provides
    @Singleton
    fun provideSessionRepository(
        testRepository: TestSessionRepository,
        realRepository: CurrentPhoenixSessionRepository
    ): SessionRepository =
        if (integrationModeEnabled()) {
            realRepository
        } else {
            testRepository
        }

    @Provides
    @Singleton
    fun provideSyncRepository(
        realRepository: CurrentPhoenixSyncRepository
    ): SyncRepository =
        if (integrationModeEnabled()) {
            realRepository
        } else {
            object : SyncRepository {
                override suspend fun syncAttendees(mode: AttendeeSyncMode): AttendeeSyncStatus? = null
                override suspend fun currentSyncStatus(): AttendeeSyncStatus? = null
                override fun observeLastSyncedStatus(identity: za.co.voelgoed.fastcheck.core.session.AuthenticatedEventIdentity): Flow<AttendeeSyncStatus?> = flowOf(null)
            }
        }

    @Provides
    @Singleton
    fun provideMobileScanRepository(
        realRepository: CurrentPhoenixMobileScanRepository,
        testRepository: TestMobileScanRepository
    ): MobileScanRepository =
        if (integrationModeEnabled()) {
            realRepository
        } else {
            testRepository
        }

    @Provides
    @Singleton
    fun provideAttendeeLookupRepository(
        realRepository: CurrentAttendeeLookupRepository
    ): AttendeeLookupRepository =
        if (integrationModeEnabled()) {
            realRepository
        } else {
            object : AttendeeLookupRepository {
                override fun search(eventId: Long, query: String): Flow<List<AttendeeSearchRecord>> =
                    flowOf(emptyList())

                override fun observeDetail(eventId: Long, attendeeId: Long): Flow<AttendeeDetailRecord?> =
                    flowOf(null)

                override suspend fun findByTicketCode(
                    eventId: Long,
                    ticketCode: String
                ): AttendeeDetailRecord? = null
            }
        }

    @Provides
    @Singleton
    fun provideScannerPreferencesStore(): ScannerPreferencesStore =
        object : ScannerPreferencesStore {
            override suspend fun loadOperatorName(): String = "Test Operator"
        }

    @Provides
    @Singleton
    fun provideEventAttendeeMetricsRepository(): EventAttendeeMetricsRepository =
        object : EventAttendeeMetricsRepository {
            override fun observeMetrics(eventId: Long): Flow<EventAttendeeCacheMetrics> =
                flowOf(
                    EventAttendeeCacheMetrics(
                        cachedAttendeeCount = 0,
                        currentlyInsideCount = 0,
                        attendeesWithRemainingCheckinsCount = 0,
                        activeOverlayCount = 0,
                        unresolvedConflictCount = 0
                    )
                )
        }

    @Provides
    @Singleton
    fun provideSessionAuthGateway(
        realGateway: CurrentSessionAuthGateway
    ): SessionAuthGateway =
        if (integrationModeEnabled()) {
            realGateway
        } else {
            object : SessionAuthGateway {
                override suspend fun currentEventId(): Long = 5
                override suspend fun currentOperatorName(): String = "Test Operator"
            }
        }

    @Provides
    @Singleton
    fun provideAdmitScanUseCase(
        realUseCase: DefaultAdmitScanUseCase
    ): AdmitScanUseCase =
        if (integrationModeEnabled()) {
            realUseCase
        } else {
            object : AdmitScanUseCase {
                override suspend fun admit(
                    ticketCode: String,
                    direction: ScanDirection,
                    operatorName: String,
                    entranceName: String
                ): LocalAdmissionDecision =
                    LocalAdmissionDecision.Rejected(
                        reason = LocalAdmissionRejectReason.InvalidTicketCode,
                        displayMessage = "Ticket not found in test repository.",
                        ticketCode = ticketCode
                    )
            }
        }

    @Provides
    @Singleton
    fun provideQueueCapturedScanUseCase(): QueueCapturedScanUseCase =
        object : QueueCapturedScanUseCase {
            override suspend fun enqueue(
                ticketCode: String,
                direction: ScanDirection,
                operatorName: String,
                entranceName: String
            ): QueueCreationResult = QueueCreationResult.InvalidTicketCode
        }

    @Provides
    @Singleton
    fun provideFlushQueuedScansUseCase(): FlushQueuedScansUseCase =
        object : FlushQueuedScansUseCase {
            override suspend fun run(maxBatchSize: Int): za.co.voelgoed.fastcheck.data.repository.FlushInvocationResult =
                za.co.voelgoed.fastcheck.data.repository.FlushInvocationResult.Attempted(
                    za.co.voelgoed.fastcheck.core.session.AuthenticatedEventIdentity(5, 1),
                    FlushReport(executionStatus = FlushExecutionStatus.COMPLETED)
                )
        }

    @Provides
    @Singleton
    fun provideAutoFlushCoordinator(): AutoFlushCoordinator =
        object : AutoFlushCoordinator {
            override val state: MutableStateFlow<AutoFlushCoordinatorState> =
                MutableStateFlow(AutoFlushCoordinatorState())

            override fun requestFlush(trigger: AutoFlushTrigger) = Unit
        }

    private fun integrationModeEnabled(): Boolean =
        runCatching {
            InstrumentationRegistry.getArguments()
                .getString("fastcheck.integration", "false")
                ?.trim()
                ?.equals("true", ignoreCase = true) == true
        }.getOrDefault(false)
}
