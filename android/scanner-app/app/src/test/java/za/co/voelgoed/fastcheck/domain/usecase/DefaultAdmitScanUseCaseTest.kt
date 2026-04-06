package za.co.voelgoed.fastcheck.domain.usecase

import com.google.common.truth.Truth.assertThat
import java.time.Clock
import java.time.Instant
import java.time.ZoneOffset
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.test.runTest
import org.junit.Test
import za.co.voelgoed.fastcheck.data.local.AttendeeEntity
import za.co.voelgoed.fastcheck.data.local.LatestFlushSnapshotEntity
import za.co.voelgoed.fastcheck.data.local.LocalAdmissionOverlayEntity
import za.co.voelgoed.fastcheck.data.local.LocalReplaySuppressionEntity
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
import za.co.voelgoed.fastcheck.domain.policy.CurrentEventAdmissionReadiness

class DefaultAdmitScanUseCaseTest {
    private val clock = Clock.fixed(Instant.parse("2026-04-06T10:00:00Z"), ZoneOffset.UTC)
    private val trustedSync =
        AttendeeSyncStatus(
            eventId = 5L,
            lastServerTime = "2026-04-06T09:55:00Z",
            lastSuccessfulSyncAt = "2026-04-06T09:55:00Z",
            syncType = "full",
            attendeeCount = 100
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
        syncStatus: AttendeeSyncStatus? = trustedSync
    ): DefaultAdmitScanUseCase {
        val syncRepo = FakeSyncRepository(syncStatus)
        return DefaultAdmitScanUseCase(
            attendeeLookupRepository = lookup,
            scannerDao = scannerDao,
            sessionAuthGateway = session,
            syncRepository = syncRepo,
            paymentStatusRuleMapper = PaymentStatusRuleMapper(),
            currentEventAdmissionReadiness = CurrentEventAdmissionReadiness(clock),
            clock = clock
        )
    }

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
        override suspend fun syncAttendees() = error("not used")

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
        override suspend fun upsertReplayCache(entry: ReplayCacheEntity) = unused()
        override suspend fun upsertReplayCache(entries: List<ReplayCacheEntity>) = unused()
        override suspend fun findReplaySuppression(ticketCode: String) = unused()
        override suspend fun deleteReplaySuppression(ticketCode: String) = unused()
        override suspend fun upsertReplaySuppression(entry: LocalReplaySuppressionEntity) = unused()
        override suspend fun loadLatestFlushSnapshot(): LatestFlushSnapshotEntity? = unused()
        override fun observeLatestFlushSnapshot(): Flow<LatestFlushSnapshotEntity?> = unused()
        override suspend fun upsertLatestFlushSnapshot(snapshot: LatestFlushSnapshotEntity) = unused()
        override suspend fun clearRecentFlushOutcomes() = unused()
        override suspend fun insertRecentFlushOutcomes(outcomes: List<RecentFlushOutcomeEntity>) = unused()
        override suspend fun loadRecentFlushOutcomes(limit: Int): List<RecentFlushOutcomeEntity> = unused()
        override fun observeRecentFlushOutcomes(): Flow<List<RecentFlushOutcomeEntity>> = unused()
        override suspend fun loadSyncMetadata(eventId: Long): SyncMetadataEntity? = unused()
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

        private fun unused(): Nothing = error("FakeScannerDao: unexpected call")
    }
}
