package za.co.voelgoed.fastcheck.data.mapper

import za.co.voelgoed.fastcheck.data.local.LatestFlushSnapshotEntity
import za.co.voelgoed.fastcheck.data.local.QueuedScanEntity
import za.co.voelgoed.fastcheck.data.local.RecentFlushOutcomeEntity
import za.co.voelgoed.fastcheck.data.remote.QueuedScanPayload
import za.co.voelgoed.fastcheck.domain.model.FlushExecutionStatus
import za.co.voelgoed.fastcheck.domain.model.FlushItemOutcome
import za.co.voelgoed.fastcheck.domain.model.FlushItemResult
import za.co.voelgoed.fastcheck.domain.model.FlushReport
import za.co.voelgoed.fastcheck.domain.model.PendingScan
import za.co.voelgoed.fastcheck.domain.model.ScanDirection

fun PendingScan.toEntity(): QueuedScanEntity =
    QueuedScanEntity(
        id = localId,
        eventId = eventId,
        ticketCode = ticketCode,
        idempotencyKey = idempotencyKey,
        createdAt = createdAt,
        scannedAt = scannedAt,
        direction = direction.name.lowercase(),
        entranceName = entranceName,
        operatorName = operatorName,
        lastAttemptAt = null
    )

fun QueuedScanEntity.toDomain(): PendingScan =
    PendingScan(
        localId = id,
        eventId = eventId,
        ticketCode = ticketCode,
        idempotencyKey = idempotencyKey,
        createdAt = createdAt,
        scannedAt = scannedAt,
        direction = ScanDirection.IN,
        entranceName = entranceName,
        operatorName = operatorName
    )

fun PendingScan.toPayload(): QueuedScanPayload =
    QueuedScanPayload(
        idempotency_key = idempotencyKey,
        ticket_code = ticketCode,
        direction = "in",
        scanned_at = scannedAt,
        entrance_name = entranceName,
        operator_name = operatorName
    )

fun FlushReport.toSnapshotEntity(completedAt: String): LatestFlushSnapshotEntity =
    LatestFlushSnapshotEntity(
        executionStatus = executionStatus.name,
        uploadedCount = uploadedCount,
        retryableRemainingCount = retryableRemainingCount,
        authExpired = authExpired,
        backlogRemaining = backlogRemaining,
        summaryMessage = summaryMessage,
        completedAt = completedAt
    )

fun FlushReport.toOutcomeEntities(completedAt: String): List<RecentFlushOutcomeEntity> =
    itemOutcomes.mapIndexed { index, outcome ->
        RecentFlushOutcomeEntity(
            outcomeOrder = index,
            idempotencyKey = outcome.idempotencyKey,
            ticketCode = outcome.ticketCode,
            outcome = outcome.outcome.name,
            message = outcome.message,
            completedAt = completedAt
        )
    }

fun toFlushReport(
    snapshot: LatestFlushSnapshotEntity,
    outcomes: List<RecentFlushOutcomeEntity>
): FlushReport =
    FlushReport(
        executionStatus = FlushExecutionStatus.valueOf(snapshot.executionStatus),
        itemOutcomes =
            outcomes.map { outcome ->
                FlushItemResult(
                    idempotencyKey = outcome.idempotencyKey,
                    ticketCode = outcome.ticketCode,
                    outcome = FlushItemOutcome.valueOf(outcome.outcome),
                    message = outcome.message
                )
            },
        uploadedCount = snapshot.uploadedCount,
        retryableRemainingCount = snapshot.retryableRemainingCount,
        authExpired = snapshot.authExpired,
        backlogRemaining = snapshot.backlogRemaining,
        summaryMessage = snapshot.summaryMessage
    )
