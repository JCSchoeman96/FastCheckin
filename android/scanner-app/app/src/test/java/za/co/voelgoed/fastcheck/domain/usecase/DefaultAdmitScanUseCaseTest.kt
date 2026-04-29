package za.co.voelgoed.fastcheck.domain.usecase

import com.google.common.truth.Truth.assertThat
import java.time.Clock
import java.time.Instant
import java.time.ZoneOffset
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.test.runTest
import org.junit.Test
import za.co.voelgoed.fastcheck.core.connectivity.ConnectivityMonitor
import za.co.voelgoed.fastcheck.core.sync.AttendeeSyncOrchestrator
import za.co.voelgoed.fastcheck.data.repository.AttendeeSyncMode
import za.co.voelgoed.fastcheck.data.local.AttendeeEntity
import za.co.voelgoed.fastcheck.data.local.LatestFlushSnapshotEntity
import za.co.voelgoed.fastcheck.data.local.LocalAdmissionOverlayEntity
import za.co.voelgoed.fastcheck.data.local.LocalReplaySuppressionEntity
import za.co.voelgoed.fastcheck.data.local.QuarantinedScanEntity
import za.co.voelgoed.fastcheck.data.local.QueuedScanEntity
import za.co.voelgoed.fastcheck.data.local.RecentFlushOutcomeEntity
import za.co.voelgoed.fastcheck.data.local.ReplayCacheEntity
import za.co.voelgoed.fastcheck.data.local.ScannerDao
import za.co.voelgoed.fastcheck.data.local.SyncMetadataEntity
import za.co.voelgoed.fastcheck.data.repository.AttendeeLookupRepository
import za.co.voelgoed.fastcheck.data.repository.PaymentStatusRuleMapper
import za.co.voelgoed.fastcheck.data.repository.SessionAuthGateway
import za.co.voelgoed.fastcheck.data.repository.SyncRepository
import za.co.voelgoed.fastcheck.domain.model.AttendeeDetailRecord
import za.co.voelgoed.fastcheck.domain.model.AttendeeSearchRecord
import za.co.voelgoed.fastcheck.domain.model.AttendeeSyncStatus
import za.co.voelgoed.fastcheck.domain.model.LocalAdmissionDecision
import za.co.voelgoed.fastcheck.domain.model.LocalAdmissionOverlayState
import za.co.voelgoed.fastcheck.domain.model.LocalAdmissionRejectReason
import za.co.voelgoed.fastcheck.domain.model.LocalAdmissionReviewReason
import za.co.voelgoed.fastcheck.domain.model.ScanDirection
import za.co.voelgoed.fastcheck.domain.policy.AttendeeSyncBootstrapGate
import za.co.voelgoed.fastcheck.domain.policy.CurrentEventAdmissionReadiness

class DefaultAdmitScanUseCaseTest {
    private val clock = Clock.fixed(Instant.parse("2026-04-06T10:00:00Z"), ZoneOffset.UTC)
    private val trustedSync =
        AttendeeSyncStatus(
            eventId = 5L,
            lastServerTime = "2026-04-06T09:55:00Z",
            lastSuccessfulSyncAt = "2026-04-06T09:55:00Z",
            syncType = "full",
            attendeeCount = 100,
            bootstrapCompletedAt = "2026-04-06T09:55:00Z"
        )

    private fun baseAttendee(
        id: Long = 1L,
        ticketCode: String = "VG-100",
        overlayState: String? = null,
        isInside: Boolean = false,
        checkinsRemaining: Int = 1,
        paymentStatus: String? = "completed"
    ): AttendeeDetailRecord =
        AttendeeDetailRecord(
            id = id,
            eventId = 5L,
            ticketCode = ticketCode,
            firstName = "Jane",
            lastName = "Doe",
            displayName = "Jane Doe",
            email = "jane@example.com",
            ticketType = "VIP",
            paymentStatus = paymentStatus,
            isCurrentlyInside = isInside,
            checkedInAt = null,
            checkedOutAt = null,
            allowedCheckins = 1,
            checkinsRemaining = checkinsRemaining,
            updatedAt = "2026-04-06T09:00:00Z",
            localOverlayState = overlayState,
            localConflictReasonCode = null,
            localConflictMessage = null,
            localOverlayScannedAt = null,
            expectedRemainingAfterOverlay = null
        )

    private fun buildUseCase(
        lookup: AttendeeLookupRepository,
        scannerDao: FakeScannerDao,
        session: SessionAuthGateway = FakeSessionAuthGateway(eventId = 5L, operatorName = "Op"),
        syncStatus: AttendeeSyncStatus? = trustedSync,
        syncRepositoryOverride: SyncRepository? = null,
        connectivityOnline: Boolean = true,
        orchestratorOverride: AttendeeSyncOrchestrator? = null
    ): DefaultAdmitScanUseCase {
        val syncRepo = syncRepositoryOverride ?: FakeSyncRepository(syncStatus)
        return DefaultAdmitScanUseCase(
            attendeeLookupRepository = lookup,
            scannerDao = scannerDao,
            sessionAuthGateway = session,
            syncRepository = syncRepo,
            paymentStatusRuleMapper = PaymentStatusRuleMapper(),
            currentEventAdmissionReadiness = CurrentEventAdmissionReadiness(clock),
            attendeeSyncBootstrapGate =
                object : AttendeeSyncBootstrapGate {
                    override fun isInitialBootstrapSyncInProgressForEvent(eventId: Long): Boolean = false
                },
            connectivityMonitor =
                object : ConnectivityMonitor {
                    override val isOnline: StateFlow<Boolean> = MutableStateFlow(connectivityOnline)
                },
            attendeeSyncOrchestrator = orchestratorOverride ?: NoopOrchestrator(),
            clock = clock
        )
    }

    private fun staleSyncStatus(): AttendeeSyncStatus =
        AttendeeSyncStatus(
            eventId = 5L,
            lastServerTime = "2026-04-06T07:00:00Z",
            lastSuccessfulSyncAt = "2026-04-06T07:00:00Z",
            syncType = "incremental",
            attendeeCount = 80,
            bootstrapCompletedAt = "2026-04-06T07:00:00Z"
        )

    @Test
    fun rejectsInvalidTicketNormalization() = runTest {
        val useCase =
            buildUseCase(
                lookup = FakeAttendeeLookupRepository(null),
                scannerDao = FakeScannerDao()
            )

        val decision = useCase.admit("   ", ScanDirection.IN, "Op", "Main")

        assertThat(decision).isInstanceOf(LocalAdmissionDecision.Rejected::class.java)
        assertThat((decision as LocalAdmissionDecision.Rejected).reason)
            .isEqualTo(LocalAdmissionRejectReason.InvalidTicketCode)
    }

    @Test
    fun reviewRequiredWhenSessionContextMissing() = runTest {
        val useCase =
            buildUseCase(
                lookup = FakeAttendeeLookupRepository(baseAttendee()),
                scannerDao = FakeScannerDao(),
                session = FakeSessionAuthGateway(eventId = null, operatorName = null)
            )

        val decision = useCase.admit("VG-100", ScanDirection.IN, "Op", "Main")

        assertThat(decision).isInstanceOf(LocalAdmissionDecision.ReviewRequired::class.java)
        assertThat((decision as LocalAdmissionDecision.ReviewRequired).reason)
            .isEqualTo(LocalAdmissionReviewReason.MissingSessionContext)
    }

    @Test
    fun reviewRequiredWhenCacheNotTrusted() = runTest {
        val useCase =
            buildUseCase(
                lookup = FakeAttendeeLookupRepository(baseAttendee()),
                scannerDao = FakeScannerDao(),
                syncStatus = null
            )

        val decision = useCase.admit("VG-100", ScanDirection.IN, "Op", "Main")

        assertThat(decision).isInstanceOf(LocalAdmissionDecision.ReviewRequired::class.java)
        assertThat((decision as LocalAdmissionDecision.ReviewRequired).reason)
            .isEqualTo(LocalAdmissionReviewReason.CacheNotTrusted)
    }

    @Test
    fun staleMissingTicketFallsBackToReviewWhenAssistSyncThrows() = runTest {
        val staleStatus = staleSyncStatus()
        val throwingSyncRepository =
            object : SyncRepository {
                var syncCalls: Int = 0

                override suspend fun syncAttendees(mode: AttendeeSyncMode): AttendeeSyncStatus? {
                    syncCalls += 1
                    throw IllegalStateException("assist failed")
                }

                override suspend fun currentSyncStatus(): AttendeeSyncStatus? = staleStatus

                override fun observeLastSyncedStatus(): Flow<AttendeeSyncStatus?> = flowOf(staleStatus)
            }
        val useCase =
            buildUseCase(
                lookup = FakeAttendeeLookupRepository(null),
                scannerDao = FakeScannerDao(),
                syncStatus = staleStatus,
                syncRepositoryOverride = throwingSyncRepository
            )

        val decision = useCase.admit("VG-404", ScanDirection.IN, "Op", "Main")

        assertThat(throwingSyncRepository.syncCalls).isEqualTo(1)
        assertThat(decision).isInstanceOf(LocalAdmissionDecision.ReviewRequired::class.java)
        assertThat((decision as LocalAdmissionDecision.ReviewRequired).reason)
            .isEqualTo(LocalAdmissionReviewReason.TicketNotInLocalAttendeeList)
    }

    @Test
    fun staleMissingTicketFallsBackToReviewWhenAssistSyncTimesOut() = runTest {
        val staleStatus = staleSyncStatus()
        val timeoutSyncRepository =
            object : SyncRepository {
                var syncCalls: Int = 0

                override suspend fun syncAttendees(mode: AttendeeSyncMode): AttendeeSyncStatus? {
                    syncCalls += 1
                    delay(1_000)
                    return staleStatus
                }

                override suspend fun currentSyncStatus(): AttendeeSyncStatus? = staleStatus

                override fun observeLastSyncedStatus(): Flow<AttendeeSyncStatus?> = flowOf(staleStatus)
            }
        val useCase =
            buildUseCase(
                lookup = FakeAttendeeLookupRepository(null),
                scannerDao = FakeScannerDao(),
                syncStatus = staleStatus,
                syncRepositoryOverride = timeoutSyncRepository
            )

        val decision = useCase.admit("VG-404", ScanDirection.IN, "Op", "Main")

        assertThat(timeoutSyncRepository.syncCalls).isEqualTo(1)
        assertThat(decision).isInstanceOf(LocalAdmissionDecision.ReviewRequired::class.java)
        assertThat((decision as LocalAdmissionDecision.ReviewRequired).reason)
            .isEqualTo(LocalAdmissionReviewReason.TicketNotInLocalAttendeeList)
    }

    @Test
    fun staleMissingTicketOfflineSkipsAssistSyncAndFallsBackToReview() = runTest {
        val staleStatus = staleSyncStatus()
        val syncRepository =
            object : SyncRepository {
                var syncCalls: Int = 0

                override suspend fun syncAttendees(mode: AttendeeSyncMode): AttendeeSyncStatus? {
                    syncCalls += 1
                    return staleStatus
                }

                override suspend fun currentSyncStatus(): AttendeeSyncStatus? = staleStatus

                override fun observeLastSyncedStatus(): Flow<AttendeeSyncStatus?> = flowOf(staleStatus)
            }
        val useCase =
            buildUseCase(
                lookup = FakeAttendeeLookupRepository(null),
                scannerDao = FakeScannerDao(),
                syncStatus = staleStatus,
                syncRepositoryOverride = syncRepository,
                connectivityOnline = false
            )

        val decision = useCase.admit("VG-404", ScanDirection.IN, "Op", "Main")

        assertThat(syncRepository.syncCalls).isEqualTo(0)
        assertThat(decision).isInstanceOf(LocalAdmissionDecision.ReviewRequired::class.java)
        assertThat((decision as LocalAdmissionDecision.ReviewRequired).reason)
            .isEqualTo(LocalAdmissionReviewReason.TicketNotInLocalAttendeeList)
    }

    @Test
    fun staleFoundAttendeeTriggersAdvisoryRefreshWithoutBlockingAdmissionDecision() = runTest {
        val staleStatus = staleSyncStatus()
        val orchestrator = RecordingOrchestrator()
        val useCase =
            buildUseCase(
                lookup = FakeAttendeeLookupRepository(baseAttendee(ticketCode = "VG-100")),
                scannerDao = FakeScannerDao(enqueueReturn = 77L),
                syncStatus = staleStatus,
                orchestratorOverride = orchestrator
            )

        val decision = useCase.admit("VG-100", ScanDirection.IN, "Op", "Main")

        assertThat(decision).isInstanceOf(LocalAdmissionDecision.Accepted::class.java)
        assertThat((decision as LocalAdmissionDecision.Accepted).localQueueId).isEqualTo(77L)
        assertThat(orchestrator.staleRefreshAdvisories).isEqualTo(1)
    }

    @Test
    fun staleAssistStructuredCancellationIsPropagated() = runTest {
        val staleStatus = staleSyncStatus()
        val cancellingRepository =
            object : SyncRepository {
                override suspend fun syncAttendees(mode: AttendeeSyncMode): AttendeeSyncStatus? {
                    throw CancellationException("cancelled")
                }

                override suspend fun currentSyncStatus(): AttendeeSyncStatus? = staleStatus

                override fun observeLastSyncedStatus(): Flow<AttendeeSyncStatus?> = flowOf(staleStatus)
            }
        val useCase =
            buildUseCase(
                lookup = FakeAttendeeLookupRepository(null),
                scannerDao = FakeScannerDao(),
                syncStatus = staleStatus,
                syncRepositoryOverride = cancellingRepository
            )

        val failure = runCatching { useCase.admit("VG-404", ScanDirection.IN, "Op", "Main") }.exceptionOrNull()
        assertThat(failure).isInstanceOf(CancellationException::class.java)
    }

    @Test
    fun rejectsTicketNotFound() = runTest {
        val useCase =
            buildUseCase(
                lookup = FakeAttendeeLookupRepository(null),
                scannerDao = FakeScannerDao()
            )

        val decision = useCase.admit("VG-999", ScanDirection.IN, "Op", "Main")

        assertThat(decision).isInstanceOf(LocalAdmissionDecision.Rejected::class.java)
        assertThat((decision as LocalAdmissionDecision.Rejected).reason)
            .isEqualTo(LocalAdmissionRejectReason.TicketNotFound)
    }

    @Test
    fun rejectsConflictDuplicateOverlay() = runTest {
        val useCase =
            buildUseCase(
                lookup =
                    FakeAttendeeLookupRepository(
                        baseAttendee(overlayState = LocalAdmissionOverlayState.CONFLICT_DUPLICATE.name)
                    ),
                scannerDao = FakeScannerDao()
            )

        val decision = useCase.admit("VG-100", ScanDirection.IN, "Op", "Main")

        assertThat(decision).isInstanceOf(LocalAdmissionDecision.Rejected::class.java)
        assertThat((decision as LocalAdmissionDecision.Rejected).reason)
            .isEqualTo(LocalAdmissionRejectReason.ConflictRequiresResolution)
    }

    @Test
    fun rejectsConflictRejectedOverlay() = runTest {
        val useCase =
            buildUseCase(
                lookup =
                    FakeAttendeeLookupRepository(
                        baseAttendee(overlayState = LocalAdmissionOverlayState.CONFLICT_REJECTED.name)
                    ),
                scannerDao = FakeScannerDao()
            )

        val decision = useCase.admit("VG-100", ScanDirection.IN, "Op", "Main")

        assertThat(decision).isInstanceOf(LocalAdmissionDecision.Rejected::class.java)
        assertThat((decision as LocalAdmissionDecision.Rejected).reason)
            .isEqualTo(LocalAdmissionRejectReason.ConflictRequiresResolution)
    }

    @Test
    fun rejectsAlreadyInside() = runTest {
        val useCase =
            buildUseCase(
                lookup = FakeAttendeeLookupRepository(baseAttendee(isInside = true)),
                scannerDao = FakeScannerDao()
            )

        val decision = useCase.admit("VG-100", ScanDirection.IN, "Op", "Main")

        assertThat(decision).isInstanceOf(LocalAdmissionDecision.Rejected::class.java)
        assertThat((decision as LocalAdmissionDecision.Rejected).reason)
            .isEqualTo(LocalAdmissionRejectReason.AlreadyInside)
    }

    @Test
    fun rejectsNoCheckinsRemaining() = runTest {
        val useCase =
            buildUseCase(
                lookup = FakeAttendeeLookupRepository(baseAttendee(checkinsRemaining = 0)),
                scannerDao = FakeScannerDao()
            )

        val decision = useCase.admit("VG-100", ScanDirection.IN, "Op", "Main")

        assertThat(decision).isInstanceOf(LocalAdmissionDecision.Rejected::class.java)
        assertThat((decision as LocalAdmissionDecision.Rejected).reason)
            .isEqualTo(LocalAdmissionRejectReason.NoCheckinsRemaining)
    }

    @Test
    fun rejectsBlockedPayment() = runTest {
        val useCase =
            buildUseCase(
                lookup = FakeAttendeeLookupRepository(baseAttendee(paymentStatus = "failed")),
                scannerDao = FakeScannerDao()
            )

        val decision = useCase.admit("VG-100", ScanDirection.IN, "Op", "Main")

        assertThat(decision).isInstanceOf(LocalAdmissionDecision.Rejected::class.java)
        assertThat((decision as LocalAdmissionDecision.Rejected).reason)
            .isEqualTo(LocalAdmissionRejectReason.PaymentBlocked)
    }

    @Test
    fun reviewRequiredForUnknownPayment() = runTest {
        val useCase =
            buildUseCase(
                lookup = FakeAttendeeLookupRepository(baseAttendee(paymentStatus = "weird_status")),
                scannerDao = FakeScannerDao()
            )

        val decision = useCase.admit("VG-100", ScanDirection.IN, "Op", "Main")

        assertThat(decision).isInstanceOf(LocalAdmissionDecision.ReviewRequired::class.java)
        assertThat((decision as LocalAdmissionDecision.ReviewRequired).reason)
            .isEqualTo(LocalAdmissionReviewReason.PaymentUnknown)
    }

    @Test
    fun acceptsAndPersistsQueueAndOverlay() = runTest {
        val dao = FakeScannerDao(enqueueReturn = 99L)
        val useCase =
            buildUseCase(
                lookup = FakeAttendeeLookupRepository(baseAttendee()),
                scannerDao = dao
            )

        val decision = useCase.admit("VG-100", ScanDirection.IN, "Op", "Main")

        assertThat(decision).isInstanceOf(LocalAdmissionDecision.Accepted::class.java)
        val accepted = decision as LocalAdmissionDecision.Accepted
        assertThat(accepted.localQueueId).isEqualTo(99L)
        assertThat(accepted.ticketCode).isEqualTo("VG-100")
        assertThat(dao.lastScan?.ticketCode).isEqualTo("VG-100")
        assertThat(dao.lastOverlay?.state).isEqualTo(LocalAdmissionOverlayState.PENDING_LOCAL.name)
    }

    @Test
    fun rejectsReplaySuppressedWhenEnqueueReturnsMinusOne() = runTest {
        val useCase =
            buildUseCase(
                lookup = FakeAttendeeLookupRepository(baseAttendee()),
                scannerDao = FakeScannerDao(enqueueReturn = -1L)
            )

        val decision = useCase.admit("VG-100", ScanDirection.IN, "Op", "Main")

        assertThat(decision).isInstanceOf(LocalAdmissionDecision.Rejected::class.java)
        assertThat((decision as LocalAdmissionDecision.Rejected).reason)
            .isEqualTo(LocalAdmissionRejectReason.ReplaySuppressed)
    }

    @Test
    fun reviewRequiredWhenLocalWriteFailsNonReplay() = runTest {
        val useCase =
            buildUseCase(
                lookup = FakeAttendeeLookupRepository(baseAttendee()),
                scannerDao = FakeScannerDao(enqueueReturn = 0L)
            )

        val decision = useCase.admit("VG-100", ScanDirection.IN, "Op", "Main")

        assertThat(decision).isInstanceOf(LocalAdmissionDecision.ReviewRequired::class.java)
        assertThat((decision as LocalAdmissionDecision.ReviewRequired).reason)
            .isEqualTo(LocalAdmissionReviewReason.LocalWriteFailed)
    }

    private class FakeAttendeeLookupRepository(
        private val attendee: AttendeeDetailRecord?
    ) : AttendeeLookupRepository {
        override fun search(eventId: Long, query: String): Flow<List<AttendeeSearchRecord>> = flowOf(emptyList())

        override fun observeDetail(eventId: Long, attendeeId: Long): Flow<AttendeeDetailRecord?> = flowOf(null)

        override suspend fun findByTicketCode(eventId: Long, ticketCode: String): AttendeeDetailRecord? = attendee
    }

    private class FakeSyncRepository(
        private val status: AttendeeSyncStatus?
    ) : SyncRepository {
        override suspend fun syncAttendees(mode: AttendeeSyncMode): AttendeeSyncStatus? = null

        override suspend fun currentSyncStatus(): AttendeeSyncStatus? = status

        override fun observeLastSyncedStatus(): Flow<AttendeeSyncStatus?> = flowOf(status)
    }

    private class FakeSessionAuthGateway(
        private val eventId: Long?,
        private val operatorName: String?
    ) : SessionAuthGateway {
        override suspend fun currentEventId(): Long? = eventId

        override suspend fun currentOperatorName(): String? = operatorName
    }

    private class NoopOrchestrator : AttendeeSyncOrchestrator {
        override fun start() = Unit

        override fun notifyAppForeground() = Unit

        override fun notifyStaleScanRefreshAdvisory() = Unit

        override fun notifyConnectivityRestored() = Unit

        override fun notifyScanDestinationActive() = Unit

        override fun notifyScanDestinationInactive() = Unit

        override suspend fun runSyncCycleNow() = Unit
    }

    private class RecordingOrchestrator : AttendeeSyncOrchestrator {
        var staleRefreshAdvisories: Int = 0

        override fun start() = Unit

        override fun notifyAppForeground() = Unit

        override fun notifyStaleScanRefreshAdvisory() {
            staleRefreshAdvisories += 1
        }

        override fun notifyConnectivityRestored() = Unit

        override fun notifyScanDestinationActive() = Unit

        override fun notifyScanDestinationInactive() = Unit

        override suspend fun runSyncCycleNow() = Unit
    }

    /**
     * Only [enqueueAcceptedAdmission] is real; [DefaultAdmitScanUseCase] does not touch other DAO methods.
     */
    private class FakeScannerDao(
        private val enqueueReturn: Long = 42L
    ) : ScannerDao {
        var lastScan: QueuedScanEntity? = null
        var lastOverlay: LocalAdmissionOverlayEntity? = null

        override suspend fun enqueueAcceptedAdmission(scan: QueuedScanEntity, overlay: LocalAdmissionOverlayEntity): Long {
            lastScan = scan
            lastOverlay = overlay
            return enqueueReturn
        }

        override suspend fun upsertAttendees(attendees: List<AttendeeEntity>) = unused()
        override suspend fun findAttendee(eventId: Long, ticketCode: String): AttendeeEntity? = unused()
        override suspend fun findAttendeeById(eventId: Long, attendeeId: Long): AttendeeEntity? = unused()
        override suspend fun deleteAllAttendees() = unused()
        override suspend fun deleteAttendeesForEvent(eventId: Long) = unused()
        override suspend fun deleteAttendeeByTicketCode(eventId: Long, ticketCode: String) = unused()
        override suspend fun countAttendeesForEvent(eventId: Long) = unused()
        override suspend fun clearEventAttendeeCacheForFullReconcile(eventId: Long) = unused()
        override suspend fun upsertLocalAdmissionOverlay(overlay: LocalAdmissionOverlayEntity): Long = unused()
        override suspend fun upsertLocalAdmissionOverlays(overlays: List<LocalAdmissionOverlayEntity>) = unused()
        override suspend fun findLatestActiveOverlayForAttendee(eventId: Long, attendeeId: Long) = unused()
        override suspend fun findLatestActiveOverlayForTicket(eventId: Long, ticketCode: String) = unused()
        override suspend fun findLocalAdmissionOverlayByIdempotencyKey(idempotencyKey: String) = unused()
        override suspend fun loadOverlaysByState(state: String) = unused()
        override suspend fun loadOverlaysForEventByState(eventId: Long, state: String) = unused()
        override suspend fun loadActiveOverlaysForEvent(eventId: Long) = unused()
        override suspend fun deleteLocalAdmissionOverlayById(overlayId: Long) = unused()
        override suspend fun updateLocalAdmissionOverlayState(
            overlayId: Long,
            state: String,
            conflictReasonCode: String?,
            conflictMessage: String?
        ) = unused()

        override suspend fun loadUnresolvedEventIdsExcluding(eventId: Long) = unused()
        override suspend fun loadAllUnresolvedEventIds() = unused()
        override suspend fun insertQueuedScan(scan: QueuedScanEntity): Long = unused()
        override suspend fun loadQueuedScans() = unused()
        override suspend fun loadQueuedScans(limit: Int) = unused()
        override suspend fun markQueuedScansReplayed(ids: List<Long>, attemptedAt: String) = unused()
        override suspend fun deleteQueuedScans(ids: List<Long>) = unused()
        override suspend fun countPendingScans() = unused()
        override fun observePendingScanCount(): Flow<Int> = unused()
        override suspend fun findReplayCache(idempotencyKey: String) = unused()
        override suspend fun clearReplayCache() = unused()
        override suspend fun upsertReplayCache(entry: ReplayCacheEntity) = unused()
        override suspend fun upsertReplayCache(entries: List<ReplayCacheEntity>) = unused()
        override suspend fun findReplaySuppression(ticketCode: String) = unused()
        override suspend fun deleteReplaySuppression(ticketCode: String) = unused()
        override suspend fun clearReplaySuppression() = unused()
        override suspend fun upsertReplaySuppression(entry: LocalReplaySuppressionEntity) = unused()
        override suspend fun loadLatestFlushSnapshot(): LatestFlushSnapshotEntity? = unused()
        override fun observeLatestFlushSnapshot(): Flow<LatestFlushSnapshotEntity?> = unused()
        override suspend fun upsertLatestFlushSnapshot(snapshot: LatestFlushSnapshotEntity) = unused()
        override suspend fun clearLatestFlushSnapshot() = unused()
        override suspend fun clearRecentFlushOutcomes() = unused()
        override suspend fun insertRecentFlushOutcomes(outcomes: List<RecentFlushOutcomeEntity>) = unused()
        override suspend fun loadRecentFlushOutcomes(limit: Int): List<RecentFlushOutcomeEntity> = unused()
        override fun observeRecentFlushOutcomes(): Flow<List<RecentFlushOutcomeEntity>> = unused()
        override suspend fun loadSyncMetadata(eventId: Long): SyncMetadataEntity? = unused()
        override suspend fun deleteAllSyncMetadata() = unused()
        override suspend fun deleteSyncMetadataForEvent(eventId: Long) = unused()
        override fun observeLatestSyncMetadata(): Flow<SyncMetadataEntity?> = unused()
        override suspend fun upsertSyncMetadata(metadata: SyncMetadataEntity) = unused()
        override suspend fun upsertAttendeesAndSyncMetadata(
            attendees: List<AttendeeEntity>,
            metadata: SyncMetadataEntity
        ) = unused()

        override suspend fun replaceLatestFlushState(
            snapshot: LatestFlushSnapshotEntity,
            outcomes: List<RecentFlushOutcomeEntity>
        ) = unused()

        override suspend fun insertQuarantinedScans(entities: List<QuarantinedScanEntity>): List<Long> = unused()

        override suspend fun countQuarantinedScans(): Int = unused()

        override fun observeQuarantinedScanCount(): Flow<Int> = unused()

        override suspend fun loadLatestQuarantinedScan(): QuarantinedScanEntity? = unused()

        override fun observeLatestQuarantinedScan(): Flow<QuarantinedScanEntity?> = unused()

        override suspend fun insertQuarantinedScansAndDeleteQueued(
            entities: List<QuarantinedScanEntity>,
            queueIds: List<Long>
        ) = unused()

        private fun unused(): Nothing = error("FakeScannerDao: unexpected call")
    }
}
