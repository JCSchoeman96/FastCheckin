package za.co.voelgoed.fastcheck.data.repository

import java.io.IOException
import java.time.Clock
import java.time.Instant
import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flatMapLatest
import za.co.voelgoed.fastcheck.core.network.SessionProvider
import za.co.voelgoed.fastcheck.data.local.LocalReplaySuppressionEntity
import za.co.voelgoed.fastcheck.data.local.ReplayCacheEntity
import za.co.voelgoed.fastcheck.data.local.QueuedScanEntity
import za.co.voelgoed.fastcheck.data.local.QuarantinedScanEntity
import za.co.voelgoed.fastcheck.data.local.ScannerDao
import za.co.voelgoed.fastcheck.data.mapper.toDomain
import za.co.voelgoed.fastcheck.data.mapper.toEntity
import za.co.voelgoed.fastcheck.data.mapper.toFlushReport
import za.co.voelgoed.fastcheck.data.mapper.toOutcomeEntities
import za.co.voelgoed.fastcheck.data.mapper.toPayload
import za.co.voelgoed.fastcheck.data.mapper.toSnapshotEntity
import za.co.voelgoed.fastcheck.data.remote.PhoenixMobileRemoteDataSource
import za.co.voelgoed.fastcheck.domain.model.FlushExecutionStatus
import za.co.voelgoed.fastcheck.domain.model.FlushItemOutcome
import za.co.voelgoed.fastcheck.domain.model.FlushItemResult
import za.co.voelgoed.fastcheck.domain.model.FlushReport
import za.co.voelgoed.fastcheck.domain.model.LocalAdmissionOverlayState
import za.co.voelgoed.fastcheck.domain.model.PendingScan
import za.co.voelgoed.fastcheck.domain.model.QueueCreationResult
import za.co.voelgoed.fastcheck.domain.model.QuarantineReason
import za.co.voelgoed.fastcheck.domain.model.QuarantineSummary

@Singleton
/**
 * Current implementation of [MobileScanRepository] for POST
 * /api/v1/mobile/scans with { "scans": [...] } payloads only.
 *
 * Successful upload classification and overlay/replay handling match the pre-quarantine baseline.
 * Additionally, certain non-retryable flush failures move the affected batch from the queue into
 * `quarantined_scans` atomically; 401, 5xx, and [IOException] never quarantine and keep the queue
 * live for retry.
 */
class CurrentPhoenixMobileScanRepository @Inject constructor(
    private val scannerDao: ScannerDao,
    private val remoteDataSource: PhoenixMobileRemoteDataSource,
    private val sessionProvider: SessionProvider,
    private val flushResultClassifier: FlushResultClassifier,
    private val clock: Clock
) : MobileScanRepository {
    override suspend fun queueScan(scan: PendingScan): QueueCreationResult {
        val now = scan.createdAt
        val replaySuppression = scannerDao.findReplaySuppression(scan.ticketCode)

        if (replaySuppression != null) {
            val ageMillis = now - replaySuppression.seenAtEpochMillis

            if (ageMillis < REPLAY_SUPPRESSION_WINDOW_MILLIS) {
                return QueueCreationResult.ReplaySuppressed
            }

            scannerDao.deleteReplaySuppression(scan.ticketCode)
        }

        scannerDao.upsertReplaySuppression(
            LocalReplaySuppressionEntity(
                ticketCode = scan.ticketCode,
                seenAtEpochMillis = now
            )
        )

        val insertedId = scannerDao.insertQueuedScan(scan.toEntity())

        return if (insertedId == -1L) {
            QueueCreationResult.ReplaySuppressed
        } else {
            QueueCreationResult.Enqueued(scan.copy(localId = insertedId))
        }
    }

    override suspend fun flushQueuedScans(maxBatchSize: Int): FlushReport {
        val queuedEntities = scannerDao.loadQueuedScans(maxBatchSize)
        val queued = queuedEntities.map { it.toDomain() }
        val token = sessionProvider.bearerToken()

        if (token.isNullOrBlank()) {
            return persistLatestFlushReport(
                FlushReport(
                    executionStatus = FlushExecutionStatus.AUTH_EXPIRED,
                    itemOutcomes = queued.map { it.toAuthExpiredOutcome() },
                    uploadedCount = 0,
                    retryableRemainingCount = queued.size,
                    authExpired = true,
                    backlogRemaining = queued.isNotEmpty(),
                    summaryMessage = "Flush stopped. Session expired and manual login is required."
                )
            )
        }

        if (queued.isEmpty()) {
            return persistLatestFlushReport(
                FlushReport(
                    executionStatus = FlushExecutionStatus.COMPLETED,
                    uploadedCount = 0,
                    retryableRemainingCount = 0,
                    authExpired = false,
                    backlogRemaining = false,
                    summaryMessage = "No queued scans to flush."
                )
            )
        }

        return try {
            val response = remoteDataSource.uploadScans(queued.map { it.toPayload() })
            when {
                response.statusCode == 401 ->
                    persistLatestFlushReport(
                        FlushReport(
                            executionStatus = FlushExecutionStatus.AUTH_EXPIRED,
                            itemOutcomes = queued.map { it.toAuthExpiredOutcome() },
                            uploadedCount = 0,
                            retryableRemainingCount = queued.size,
                            httpStatusCode = response.statusCode,
                            authExpired = true,
                            backlogRemaining = queued.isNotEmpty(),
                            summaryMessage = "Flush stopped. Session expired and manual login is required."
                        )
                    )

                response.statusCode == 429 ->
                    persistLatestFlushReport(
                        FlushReport(
                            executionStatus = FlushExecutionStatus.RETRYABLE_FAILURE,
                            itemOutcomes =
                                queued.map { pendingScan ->
                                    pendingScan.toRetryableOutcome("Server rate limit reached during scan upload.")
                                },
                            uploadedCount = 0,
                            retryableRemainingCount = queued.size,
                            httpStatusCode = response.statusCode,
                            retryAfterMillis = response.retryAfterMillis,
                            rateLimitLimit = response.rateLimitLimit,
                            rateLimitRemaining = response.rateLimitRemaining,
                            rateLimitResetEpochSeconds = response.rateLimitResetEpochSeconds,
                            backpressureObserved = true,
                            authExpired = false,
                            backlogRemaining = queued.isNotEmpty(),
                            summaryMessage =
                                if (response.retryAfterMillis != null) {
                                    "Flush paused because the server requested a retry delay."
                                } else {
                                    "Flush paused because the server rate-limited scan uploads."
                                }
                        )
                    )

                response.statusCode >= 500 ->
                    persistLatestFlushReport(
                        FlushReport(
                            executionStatus = FlushExecutionStatus.RETRYABLE_FAILURE,
                            itemOutcomes =
                                queued.map { pendingScan ->
                                    pendingScan.toRetryableOutcome("Server error during scan upload.")
                                },
                            uploadedCount = 0,
                            retryableRemainingCount = queued.size,
                            httpStatusCode = response.statusCode,
                            retryAfterMillis = response.retryAfterMillis,
                            rateLimitLimit = response.rateLimitLimit,
                            rateLimitRemaining = response.rateLimitRemaining,
                            rateLimitResetEpochSeconds = response.rateLimitResetEpochSeconds,
                            backpressureObserved = response.statusCode == 503 || response.retryAfterMillis != null,
                            authExpired = false,
                            backlogRemaining = queued.isNotEmpty(),
                            summaryMessage = "Flush failed with a retryable server error."
                        )
                    )

                response.statusCode !in 200..299 ->
                    quarantineAttemptedBatch(
                        queuedEntities = queuedEntities,
                        reason = QuarantineReason.UNRECOVERABLE_API_CONTRACT_ERROR,
                        message = httpResponseDetail(response.statusCode, response.errorBody),
                        batchAttributed = true
                    )

                else -> {
                    val responseBody =
                        requireNotNull(response.body) {
                            httpResponseDetail(response.statusCode, response.errorBody)
                        }
                    val payload =
                        requireNotNull(responseBody.data) {
                            responseBody.message ?: responseBody.error ?: "Upload failed"
                        }
                    val outcomes = flushResultClassifier.classify(queued, payload.results)
                    val terminalOutcomes = outcomes.filter { it.outcome != FlushItemOutcome.RETRYABLE_FAILURE }
                    val matchedIds =
                        terminalOutcomes.mapNotNull { outcome ->
                            queued.firstOrNull { it.idempotencyKey == outcome.idempotencyKey }?.localId
                        }
                    val now = Instant.ofEpochMilli(clock.millis()).toString()

                    if (terminalOutcomes.isNotEmpty()) {
                        scannerDao.upsertReplayCache(
                            terminalOutcomes.map { outcome ->
                                ReplayCacheEntity(
                                    idempotencyKey = outcome.idempotencyKey,
                                    status = outcome.outcome.name.lowercase(),
                                    message = outcome.message,
                                    reasonCode = outcome.reasonCode,
                                    storedAt = now,
                                    terminal = true
                                )
                            }
                        )

                        terminalOutcomes.forEach { outcome ->
                            transitionOverlayForFlushOutcome(outcome)
                        }
                    }

                    if (matchedIds.isNotEmpty()) {
                        scannerDao.deleteQueuedScans(matchedIds)
                    }

                    val remainingCount = scannerDao.countPendingScans()
                    persistLatestFlushReport(
                        FlushReport(
                            executionStatus = FlushExecutionStatus.COMPLETED,
                            itemOutcomes = outcomes,
                            uploadedCount = terminalOutcomes.size,
                            retryableRemainingCount =
                                outcomes.count { it.outcome == FlushItemOutcome.RETRYABLE_FAILURE },
                            httpStatusCode = response.statusCode,
                            rateLimitLimit = response.rateLimitLimit,
                            rateLimitRemaining = response.rateLimitRemaining,
                            rateLimitResetEpochSeconds = response.rateLimitResetEpochSeconds,
                            backpressureObserved = false,
                            authExpired = false,
                            backlogRemaining = remainingCount > 0,
                            summaryMessage =
                                if (outcomes.any { it.outcome == FlushItemOutcome.RETRYABLE_FAILURE }) {
                                    "Flush completed with retry backlog."
                                } else {
                                    "Flush completed. ${terminalOutcomes.size} queued scans classified."
                                }
                        )
                    )
                }
            }
        } catch (_exception: IllegalArgumentException) {
            quarantineAttemptedBatch(
                queuedEntities = queuedEntities,
                reason = QuarantineReason.INCOMPLETE_SERVER_RESPONSE,
                message = "Flush failed because the server response was incomplete.",
                batchAttributed = true
            )
        } catch (_exception: IOException) {
            persistLatestFlushReport(
                FlushReport(
                    executionStatus = FlushExecutionStatus.RETRYABLE_FAILURE,
                    itemOutcomes =
                        queued.map { pendingScan ->
                            pendingScan.toRetryableOutcome("Network failure during scan upload.")
                        },
                    uploadedCount = 0,
                    retryableRemainingCount = queued.size,
                    backpressureObserved = true,
                    authExpired = false,
                    backlogRemaining = queued.isNotEmpty(),
                    summaryMessage = "Flush failed with a retryable network error."
                )
            )
        }
    }

    override suspend fun pendingQueueDepth(): Int = scannerDao.countPendingScans()

    override suspend fun latestFlushReport(): FlushReport? {
        val snapshot = scannerDao.loadLatestFlushSnapshot() ?: return null
        return toFlushReport(snapshot, scannerDao.loadRecentFlushOutcomes())
    }

    override fun observePendingQueueDepth(): Flow<Int> = scannerDao.observePendingScanCount()

    @OptIn(ExperimentalCoroutinesApi::class)
    override fun observeLatestFlushReport(): Flow<FlushReport?> =
        // Avoid combining two independently-updating flows (snapshot + outcomes), which can
        // transiently produce mismatched pairs (new snapshot + old outcomes, or vice versa).
        //
        // `replaceLatestFlushState()` writes snapshot and outcomes in a single Room transaction.
        // By driving from the snapshot emission and reading outcomes at that point, we reduce
        // the chance of UI “flicker” to essentially the Room commit boundary.
        scannerDao.observeLatestFlushSnapshot().flatMapLatest { snapshot ->
            flow {
                if (snapshot == null) {
                    emit(null)
                } else {
                    emit(toFlushReport(snapshot, scannerDao.loadRecentFlushOutcomes()))
                }
            }
        }

    override suspend fun quarantineCount(): Int = scannerDao.countQuarantinedScans()

    override suspend fun latestQuarantineSummary(): QuarantineSummary? {
        val count = scannerDao.countQuarantinedScans()
        if (count == 0) return null
        val latest = scannerDao.loadLatestQuarantinedScan() ?: return null
        return latest.toQuarantineSummary(count)
    }

    override fun observeQuarantineCount(): Flow<Int> = scannerDao.observeQuarantinedScanCount()

    override fun observeLatestQuarantineSummary(): Flow<QuarantineSummary?> =
        combine(
            scannerDao.observeQuarantinedScanCount(),
            scannerDao.observeLatestQuarantinedScan()
        ) { count, latest ->
            if (count == 0) null else latest?.toQuarantineSummary(count)
        }

    private fun QuarantinedScanEntity.toQuarantineSummary(totalCount: Int): QuarantineSummary =
        QuarantineSummary(
            totalCount = totalCount,
            latestReason = QuarantineReason.fromWire(quarantineReason),
            latestMessage = quarantineMessage,
            latestQuarantinedAt = quarantinedAt
        )

    private suspend fun quarantineAttemptedBatch(
        queuedEntities: List<QueuedScanEntity>,
        reason: QuarantineReason,
        message: String,
        batchAttributed: Boolean
    ): FlushReport {
        if (queuedEntities.isEmpty()) {
            return persistLatestFlushReport(
                FlushReport(
                    executionStatus = FlushExecutionStatus.COMPLETED,
                    uploadedCount = 0,
                    retryableRemainingCount = 0,
                    authExpired = false,
                    backlogRemaining = false,
                    summaryMessage = "No queued scans to quarantine."
                )
            )
        }

        val quarantinedAt = Instant.ofEpochMilli(clock.millis()).toString()
        val rows =
            queuedEntities.map { row ->
                val overlay =
                    scannerDao.findLocalAdmissionOverlayByIdempotencyKey(row.idempotencyKey)
                QuarantinedScanEntity(
                    originalQueueId = row.id,
                    eventId = row.eventId,
                    ticketCode = row.ticketCode,
                    idempotencyKey = row.idempotencyKey,
                    createdAt = row.createdAt,
                    scannedAt = row.scannedAt,
                    direction = row.direction,
                    entranceName = row.entranceName,
                    operatorName = row.operatorName,
                    lastAttemptAt = row.lastAttemptAt,
                    quarantineReason = reason.wireValue,
                    quarantineMessage = message,
                    quarantinedAt = quarantinedAt,
                    batchAttributed = batchAttributed,
                    overlayStateAtQuarantine = overlay?.state
                )
            }

        scannerDao.insertQuarantinedScansAndDeleteQueued(
            entities = rows,
            queueIds = queuedEntities.map { it.id }
        )

        val remaining = scannerDao.countPendingScans()
        return persistLatestFlushReport(
            FlushReport(
                executionStatus = FlushExecutionStatus.COMPLETED,
                itemOutcomes = emptyList(),
                uploadedCount = 0,
                retryableRemainingCount = remaining,
                authExpired = false,
                backlogRemaining = remaining > 0,
                summaryMessage =
                    "Quarantined ${queuedEntities.size} unrecoverable queued scan(s) " +
                        "and removed them from the retry backlog."
            )
        )
    }

    private fun httpResponseDetail(statusCode: Int, body: String?): String =
        if (body.isNullOrBlank()) "HTTP $statusCode" else "HTTP $statusCode: $body"

    private suspend fun persistLatestFlushReport(report: FlushReport): FlushReport {
        val completedAt = Instant.ofEpochMilli(clock.millis()).toString()

        scannerDao.replaceLatestFlushState(
            snapshot = report.toSnapshotEntity(completedAt),
            outcomes = report.toOutcomeEntities(completedAt)
        )

        return report
    }

    private suspend fun transitionOverlayForFlushOutcome(outcome: FlushItemResult) {
        val overlay =
            scannerDao.findLocalAdmissionOverlayByIdempotencyKey(outcome.idempotencyKey)
                ?: return

        val nextState =
            when (outcome.outcome) {
                FlushItemOutcome.SUCCESS ->
                    OverlayTransition(
                        state = LocalAdmissionOverlayState.CONFIRMED_LOCAL_UNSYNCED,
                        conflictReasonCode = null,
                        conflictMessage = null
                    )

                FlushItemOutcome.DUPLICATE ->
                    OverlayTransition(
                        state = LocalAdmissionOverlayState.CONFLICT_DUPLICATE,
                        conflictReasonCode = outcome.reasonCode ?: "duplicate",
                        conflictMessage = outcome.message
                    )

                FlushItemOutcome.TERMINAL_ERROR ->
                    if (outcome.reasonCode == "business_duplicate") {
                        OverlayTransition(
                            state = LocalAdmissionOverlayState.CONFLICT_DUPLICATE,
                            conflictReasonCode = outcome.reasonCode,
                            conflictMessage = outcome.message
                        )
                    } else {
                        OverlayTransition(
                            state = LocalAdmissionOverlayState.CONFLICT_REJECTED,
                            conflictReasonCode = outcome.reasonCode ?: "terminal_error",
                            conflictMessage = outcome.message
                        )
                    }

                FlushItemOutcome.RETRYABLE_FAILURE,
                FlushItemOutcome.AUTH_EXPIRED -> null
            }

        if (nextState != null) {
            scannerDao.updateLocalAdmissionOverlayState(
                overlayId = overlay.id,
                state = nextState.state.name,
                conflictReasonCode = nextState.conflictReasonCode,
                conflictMessage = nextState.conflictMessage
            )
        }
    }

    private fun PendingScan.toAuthExpiredOutcome(): FlushItemResult =
        FlushItemResult(
            idempotencyKey = idempotencyKey,
            ticketCode = ticketCode,
            outcome = FlushItemOutcome.AUTH_EXPIRED,
            message = "Manual login required before queued scans can flush."
        )

    private fun PendingScan.toRetryableOutcome(message: String): FlushItemResult =
        FlushItemResult(
            idempotencyKey = idempotencyKey,
            ticketCode = ticketCode,
            outcome = FlushItemOutcome.RETRYABLE_FAILURE,
            message = message
        )

    private companion object {
        const val REPLAY_SUPPRESSION_WINDOW_MILLIS: Long = 3_000L
    }

    private data class OverlayTransition(
        val state: LocalAdmissionOverlayState,
        val conflictReasonCode: String?,
        val conflictMessage: String?
    )
}
