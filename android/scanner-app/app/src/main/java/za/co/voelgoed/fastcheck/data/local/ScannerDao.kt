package za.co.voelgoed.fastcheck.data.local

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import androidx.room.Transaction
import androidx.room.Upsert
import kotlinx.coroutines.flow.Flow
import za.co.voelgoed.fastcheck.domain.policy.AdmissionRuntimePolicy

@Dao
interface ScannerDao {
    @Upsert
    suspend fun upsertAttendees(attendees: List<AttendeeEntity>)

    @Query("SELECT * FROM attendees WHERE eventId = :eventId AND ticketCode = :ticketCode LIMIT 1")
    suspend fun findAttendee(eventId: Long, ticketCode: String): AttendeeEntity?

    @Query("SELECT * FROM attendees WHERE eventId = :eventId AND id = :attendeeId LIMIT 1")
    suspend fun findAttendeeById(
        eventId: Long,
        attendeeId: Long
    ): AttendeeEntity?

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsertLocalAdmissionOverlay(overlay: LocalAdmissionOverlayEntity): Long

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsertLocalAdmissionOverlays(overlays: List<LocalAdmissionOverlayEntity>)

    @Query(
        """
        SELECT * FROM local_admission_overlays
        WHERE eventId = :eventId
            AND attendeeId = :attendeeId
            AND state IN (
                'PENDING_LOCAL',
                'CONFIRMED_LOCAL_UNSYNCED',
                'CONFLICT_DUPLICATE',
                'CONFLICT_REJECTED'
            )
        ORDER BY createdAtEpochMillis DESC, id DESC
        LIMIT 1
        """
    )
    suspend fun findLatestActiveOverlayForAttendee(
        eventId: Long,
        attendeeId: Long
    ): LocalAdmissionOverlayEntity?

    @Query(
        """
        SELECT * FROM local_admission_overlays
        WHERE eventId = :eventId
            AND ticketCode = :ticketCode
            AND state IN (
                'PENDING_LOCAL',
                'CONFIRMED_LOCAL_UNSYNCED',
                'CONFLICT_DUPLICATE',
                'CONFLICT_REJECTED'
            )
        ORDER BY createdAtEpochMillis DESC, id DESC
        LIMIT 1
        """
    )
    suspend fun findLatestActiveOverlayForTicket(
        eventId: Long,
        ticketCode: String
    ): LocalAdmissionOverlayEntity?

    @Query(
        """
        SELECT * FROM local_admission_overlays
        WHERE idempotencyKey = :idempotencyKey
        LIMIT 1
        """
    )
    suspend fun findLocalAdmissionOverlayByIdempotencyKey(
        idempotencyKey: String
    ): LocalAdmissionOverlayEntity?

    @Query(
        """
        SELECT * FROM local_admission_overlays
        WHERE state = :state
        ORDER BY createdAtEpochMillis ASC, id ASC
        """
    )
    suspend fun loadOverlaysByState(state: String): List<LocalAdmissionOverlayEntity>

    @Query(
        """
        SELECT * FROM local_admission_overlays
        WHERE eventId = :eventId
            AND state = :state
        ORDER BY createdAtEpochMillis ASC, id ASC
        """
    )
    suspend fun loadOverlaysForEventByState(
        eventId: Long,
        state: String
    ): List<LocalAdmissionOverlayEntity>

    @Query(
        """
        SELECT * FROM local_admission_overlays
        WHERE eventId = :eventId
            AND state IN (
                'PENDING_LOCAL',
                'CONFIRMED_LOCAL_UNSYNCED',
                'CONFLICT_DUPLICATE',
                'CONFLICT_REJECTED'
            )
        ORDER BY createdAtEpochMillis ASC, id ASC
        """
    )
    suspend fun loadActiveOverlaysForEvent(eventId: Long): List<LocalAdmissionOverlayEntity>

    @Query("DELETE FROM local_admission_overlays WHERE id = :overlayId")
    suspend fun deleteLocalAdmissionOverlayById(overlayId: Long)

    @Query(
        """
        UPDATE local_admission_overlays
        SET state = :state,
            conflictReasonCode = :conflictReasonCode,
            conflictMessage = :conflictMessage
        WHERE id = :overlayId
        """
    )
    suspend fun updateLocalAdmissionOverlayState(
        overlayId: Long,
        state: String,
        conflictReasonCode: String?,
        conflictMessage: String?
    )

    @Query(
        """
        SELECT DISTINCT eventId
        FROM (
            SELECT eventId
            FROM queued_scans
            WHERE replayed = 0
            UNION ALL
            SELECT eventId
            FROM local_admission_overlays
            WHERE state IN (
                'PENDING_LOCAL',
                'CONFIRMED_LOCAL_UNSYNCED',
                'CONFLICT_DUPLICATE',
                'CONFLICT_REJECTED'
            )
        )
        WHERE eventId != :eventId
        ORDER BY eventId ASC
        """
    )
    suspend fun loadUnresolvedEventIdsExcluding(eventId: Long): List<Long>

    @Query(
        """
        SELECT DISTINCT eventId
        FROM (
            SELECT eventId
            FROM queued_scans
            WHERE replayed = 0
            UNION ALL
            SELECT eventId
            FROM local_admission_overlays
            WHERE state IN (
                'PENDING_LOCAL',
                'CONFIRMED_LOCAL_UNSYNCED',
                'CONFLICT_DUPLICATE',
                'CONFLICT_REJECTED'
            )
        )
        ORDER BY eventId ASC
        """
    )
    suspend fun loadAllUnresolvedEventIds(): List<Long>

    @Insert(onConflict = OnConflictStrategy.IGNORE)
    suspend fun insertQueuedScan(scan: QueuedScanEntity): Long

    @Query("SELECT * FROM queued_scans WHERE replayed = 0 ORDER BY createdAt ASC, id ASC")
    suspend fun loadQueuedScans(): List<QueuedScanEntity>

    @Query("SELECT * FROM queued_scans WHERE replayed = 0 ORDER BY createdAt ASC, id ASC LIMIT :limit")
    suspend fun loadQueuedScans(limit: Int): List<QueuedScanEntity>

    @Query("UPDATE queued_scans SET replayed = 1, lastAttemptAt = :attemptedAt WHERE id IN (:ids)")
    suspend fun markQueuedScansReplayed(ids: List<Long>, attemptedAt: String)

    @Query("DELETE FROM queued_scans WHERE id IN (:ids)")
    suspend fun deleteQueuedScans(ids: List<Long>)

    @Insert(onConflict = OnConflictStrategy.ABORT)
    suspend fun insertQuarantinedScans(entities: List<QuarantinedScanEntity>): List<Long>

    @Query("SELECT COUNT(*) FROM quarantined_scans")
    suspend fun countQuarantinedScans(): Int

    @Query("SELECT COUNT(*) FROM quarantined_scans")
    fun observeQuarantinedScanCount(): Flow<Int>

    @Query(
        """
        SELECT * FROM quarantined_scans
        ORDER BY quarantinedAt DESC, id DESC
        LIMIT 1
        """
    )
    suspend fun loadLatestQuarantinedScan(): QuarantinedScanEntity?

    @Query(
        """
        SELECT * FROM quarantined_scans
        ORDER BY quarantinedAt DESC, id DESC
        LIMIT 1
        """
    )
    fun observeLatestQuarantinedScan(): Flow<QuarantinedScanEntity?>

    @Transaction
    suspend fun insertQuarantinedScansAndDeleteQueued(
        entities: List<QuarantinedScanEntity>,
        queueIds: List<Long>
    ) {
        if (entities.isNotEmpty()) {
            insertQuarantinedScans(entities)
        }
        if (queueIds.isNotEmpty()) {
            deleteQueuedScans(queueIds)
        }
    }

    @Query("SELECT COUNT(*) FROM queued_scans WHERE replayed = 0")
    suspend fun countPendingScans(): Int

    @Query("SELECT COUNT(*) FROM queued_scans WHERE replayed = 0")
    fun observePendingScanCount(): Flow<Int>

    @Query("SELECT * FROM scan_replay_cache WHERE idempotencyKey = :idempotencyKey LIMIT 1")
    suspend fun findReplayCache(idempotencyKey: String): ReplayCacheEntity?

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsertReplayCache(entry: ReplayCacheEntity)

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsertReplayCache(entries: List<ReplayCacheEntity>)

    @Query("SELECT * FROM local_replay_suppression WHERE ticketCode = :ticketCode LIMIT 1")
    suspend fun findReplaySuppression(ticketCode: String): LocalReplaySuppressionEntity?

    @Query("DELETE FROM local_replay_suppression WHERE ticketCode = :ticketCode")
    suspend fun deleteReplaySuppression(ticketCode: String)

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsertReplaySuppression(entry: LocalReplaySuppressionEntity)

    @Query("SELECT * FROM latest_flush_snapshot WHERE snapshotId = 1 LIMIT 1")
    suspend fun loadLatestFlushSnapshot(): LatestFlushSnapshotEntity?

    @Query("SELECT * FROM latest_flush_snapshot WHERE snapshotId = 1 LIMIT 1")
    fun observeLatestFlushSnapshot(): Flow<LatestFlushSnapshotEntity?>

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsertLatestFlushSnapshot(snapshot: LatestFlushSnapshotEntity)

    @Query("DELETE FROM recent_flush_outcomes")
    suspend fun clearRecentFlushOutcomes()

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insertRecentFlushOutcomes(outcomes: List<RecentFlushOutcomeEntity>)

    @Query("SELECT * FROM recent_flush_outcomes ORDER BY outcomeOrder ASC LIMIT :limit")
    suspend fun loadRecentFlushOutcomes(limit: Int = 5): List<RecentFlushOutcomeEntity>

    @Query("SELECT * FROM recent_flush_outcomes ORDER BY outcomeOrder ASC LIMIT 5")
    fun observeRecentFlushOutcomes(): Flow<List<RecentFlushOutcomeEntity>>

    @Query("SELECT * FROM sync_metadata WHERE eventId = :eventId LIMIT 1")
    suspend fun loadSyncMetadata(eventId: Long): SyncMetadataEntity?

    @Query(
        """
        SELECT * FROM sync_metadata
        WHERE lastSuccessfulSyncAt IS NOT NULL
        ORDER BY lastSuccessfulSyncAt DESC
        LIMIT 1
        """
    )
    // TODO(B3-techdebt): Latest sync ordering assumption.
    // This query orders by `lastSuccessfulSyncAt`, which is currently derived from the backend
    // payload time. We treat it as a proxy for “latest successful local sync”.
    // If server_time can be out-of-order or otherwise unstable, introduce a local completion
    // timestamp (e.g. syncedAtEpochMs) and order by that instead.
    fun observeLatestSyncMetadata(): Flow<SyncMetadataEntity?>

    @Upsert
    suspend fun upsertSyncMetadata(metadata: SyncMetadataEntity)

    @Transaction
    suspend fun upsertAttendeesAndSyncMetadata(
        attendees: List<AttendeeEntity>,
        metadata: SyncMetadataEntity
    ) {
        // Keep this atomic helper for callers that need one local boundary.
        // Paged attendee sync intentionally persists attendees progressively and commits metadata later.
        upsertAttendees(attendees)
        upsertSyncMetadata(metadata)
    }

    @Transaction
    suspend fun replaceLatestFlushState(
        snapshot: LatestFlushSnapshotEntity,
        outcomes: List<RecentFlushOutcomeEntity>
    ) {
        upsertLatestFlushSnapshot(snapshot)
        clearRecentFlushOutcomes()

        if (outcomes.isNotEmpty()) {
            insertRecentFlushOutcomes(outcomes)
        }
    }

    @Transaction
    suspend fun enqueueAcceptedAdmission(
        scan: QueuedScanEntity,
        overlay: LocalAdmissionOverlayEntity
    ): Long {
        val replaySuppression = findReplaySuppression(scan.ticketCode)
        if (replaySuppression != null) {
            val ageMillis = scan.createdAt - replaySuppression.seenAtEpochMillis
            if (ageMillis < AdmissionRuntimePolicy.LOCAL_REPLAY_SUPPRESSION_WINDOW.toMillis()) {
                return -1L
            }

            deleteReplaySuppression(scan.ticketCode)
        }

        val insertedId = insertQueuedScan(scan)
        if (insertedId == -1L) return -1L

        upsertLocalAdmissionOverlay(overlay)
        upsertReplaySuppression(
            LocalReplaySuppressionEntity(
                ticketCode = scan.ticketCode,
                seenAtEpochMillis = scan.createdAt
            )
        )
        return insertedId
    }
}
