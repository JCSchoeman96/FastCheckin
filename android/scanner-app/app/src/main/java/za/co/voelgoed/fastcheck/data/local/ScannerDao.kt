package za.co.voelgoed.fastcheck.data.local

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import androidx.room.Transaction
import kotlinx.coroutines.flow.Flow

@Dao
interface ScannerDao {
    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsertAttendees(attendees: List<AttendeeEntity>)

    @Query("SELECT * FROM attendees WHERE eventId = :eventId AND ticketCode = :ticketCode LIMIT 1")
    suspend fun findAttendee(eventId: Long, ticketCode: String): AttendeeEntity?

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

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsertSyncMetadata(metadata: SyncMetadataEntity)

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
}
