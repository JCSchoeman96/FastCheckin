package za.co.voelgoed.fastcheck.domain.usecase

import java.time.Clock
import java.time.Instant
import java.util.UUID
import javax.inject.Inject
import za.co.voelgoed.fastcheck.core.ticket.TicketCodeNormalizer
import za.co.voelgoed.fastcheck.data.local.LocalAdmissionOverlayEntity
import za.co.voelgoed.fastcheck.data.local.QueuedScanEntity
import za.co.voelgoed.fastcheck.data.local.ScannerDao
import za.co.voelgoed.fastcheck.data.repository.AttendeeLookupRepository
import za.co.voelgoed.fastcheck.data.repository.PaymentStatusRuleMapper
import za.co.voelgoed.fastcheck.data.repository.SessionAuthGateway
import za.co.voelgoed.fastcheck.data.repository.SyncRepository
import za.co.voelgoed.fastcheck.domain.model.LocalAdmissionDecision
import za.co.voelgoed.fastcheck.domain.model.LocalAdmissionOverlayState
import za.co.voelgoed.fastcheck.domain.model.LocalAdmissionRejectReason
import za.co.voelgoed.fastcheck.domain.model.LocalAdmissionReviewReason
import za.co.voelgoed.fastcheck.domain.model.PaymentStatusDecision
import za.co.voelgoed.fastcheck.domain.model.ScanDirection
import za.co.voelgoed.fastcheck.domain.policy.CurrentEventAdmissionReadiness

class DefaultAdmitScanUseCase @Inject constructor(
    private val attendeeLookupRepository: AttendeeLookupRepository,
    private val scannerDao: ScannerDao,
    private val sessionAuthGateway: SessionAuthGateway,
    private val syncRepository: SyncRepository,
    private val paymentStatusRuleMapper: PaymentStatusRuleMapper,
    private val currentEventAdmissionReadiness: CurrentEventAdmissionReadiness,
    private val clock: Clock
) : AdmitScanUseCase {
    override suspend fun admit(
        ticketCode: String,
        direction: ScanDirection,
        operatorName: String,
        entranceName: String
    ): LocalAdmissionDecision {
        val canonicalTicketCode =
            TicketCodeNormalizer.normalizeOrNull(ticketCode)
                ?: return LocalAdmissionDecision.Rejected(
                    reason = LocalAdmissionRejectReason.InvalidTicketCode,
                    displayMessage = "Invalid scan. Ticket code could not be read.",
                    ticketCode = ticketCode
                )

        val eventId =
            sessionAuthGateway.currentEventId()
                ?: return LocalAdmissionDecision.ReviewRequired(
                    reason = LocalAdmissionReviewReason.MissingSessionContext,
                    displayMessage = "Login is required before local admission can continue.",
                    ticketCode = canonicalTicketCode
                )

        val syncStatus = syncRepository.currentSyncStatus()
        if (!currentEventAdmissionReadiness.hasTrustedCurrentEventCache(eventId, syncStatus)) {
            return LocalAdmissionDecision.ReviewRequired(
                reason = LocalAdmissionReviewReason.CacheNotTrusted,
                displayMessage = "Attendee cache is not trusted enough for a green admission decision yet.",
                ticketCode = canonicalTicketCode
            )
        }

        val attendee =
            attendeeLookupRepository.findByTicketCode(eventId, canonicalTicketCode)
                ?: return LocalAdmissionDecision.Rejected(
                    reason = LocalAdmissionRejectReason.TicketNotFound,
                    displayMessage = "Invalid scan. Ticket not found for this event.",
                    ticketCode = canonicalTicketCode
                )

        if (
            attendee.localOverlayState == LocalAdmissionOverlayState.CONFLICT_DUPLICATE.name ||
                attendee.localOverlayState == LocalAdmissionOverlayState.CONFLICT_REJECTED.name
        ) {
            return LocalAdmissionDecision.Rejected(
                reason = LocalAdmissionRejectReason.ConflictRequiresResolution,
                displayMessage =
                    attendee.localConflictMessage
                        ?: "Invalid scan. This attendee has an unresolved reconciliation conflict.",
                ticketCode = canonicalTicketCode,
                displayName = attendee.displayName
            )
        }

        if (attendee.isCurrentlyInside) {
            return LocalAdmissionDecision.Rejected(
                reason = LocalAdmissionRejectReason.AlreadyInside,
                displayMessage = "Invalid scan. This attendee is already inside.",
                ticketCode = canonicalTicketCode,
                displayName = attendee.displayName
            )
        }

        if (attendee.checkinsRemaining <= 0) {
            return LocalAdmissionDecision.Rejected(
                reason = LocalAdmissionRejectReason.NoCheckinsRemaining,
                displayMessage = "Invalid scan. No check-ins remain for this attendee.",
                ticketCode = canonicalTicketCode,
                displayName = attendee.displayName
            )
        }

        when (paymentStatusRuleMapper.map(attendee.paymentStatus)) {
            PaymentStatusDecision.BLOCKED ->
                return LocalAdmissionDecision.Rejected(
                    reason = LocalAdmissionRejectReason.PaymentBlocked,
                    displayMessage = "Invalid scan. Payment status does not allow admission.",
                    ticketCode = canonicalTicketCode,
                    displayName = attendee.displayName
                )

            PaymentStatusDecision.UNKNOWN ->
                return LocalAdmissionDecision.ReviewRequired(
                    reason = LocalAdmissionReviewReason.PaymentUnknown,
                    displayMessage = "Payment status needs manual review before admission.",
                    ticketCode = canonicalTicketCode,
                    displayName = attendee.displayName
                )

            PaymentStatusDecision.ALLOWED -> Unit
        }

        val effectiveOperator = sessionAuthGateway.currentOperatorName() ?: operatorName.trim()
        val createdAtEpochMillis = clock.millis()
        val scannedAt = Instant.ofEpochMilli(createdAtEpochMillis).toString()
        val idempotencyKey = UUID.randomUUID().toString()
        val expectedRemainingAfterOverlay = (attendee.checkinsRemaining - 1).coerceAtLeast(0)

        val insertedQueueId =
            scannerDao.enqueueAcceptedAdmission(
                scan =
                    QueuedScanEntity(
                        eventId = eventId,
                        ticketCode = canonicalTicketCode,
                        idempotencyKey = idempotencyKey,
                        createdAt = createdAtEpochMillis,
                        scannedAt = scannedAt,
                        direction = direction.name.lowercase(),
                        entranceName = entranceName,
                        operatorName = effectiveOperator
                    ),
                overlay =
                    LocalAdmissionOverlayEntity(
                        eventId = eventId,
                        attendeeId = attendee.id,
                        ticketCode = canonicalTicketCode,
                        idempotencyKey = idempotencyKey,
                        direction = direction.name.lowercase(),
                        state = LocalAdmissionOverlayState.PENDING_LOCAL.name,
                        createdAtEpochMillis = createdAtEpochMillis,
                        overlayScannedAt = scannedAt,
                        expectedRemainingAfterOverlay = expectedRemainingAfterOverlay,
                        operatorName = effectiveOperator,
                        entranceName = entranceName
                    )
            )

        if (insertedQueueId == -1L) {
            return LocalAdmissionDecision.Rejected(
                reason = LocalAdmissionRejectReason.ReplaySuppressed,
                displayMessage = "Invalid scan. Same ticket was just scanned on this device.",
                ticketCode = canonicalTicketCode,
                displayName = attendee.displayName
            )
        }

        if (insertedQueueId <= 0L) {
            return LocalAdmissionDecision.ReviewRequired(
                reason = LocalAdmissionReviewReason.LocalWriteFailed,
                displayMessage = "Local admission could not be written safely. Manual review is required.",
                ticketCode = canonicalTicketCode,
                displayName = attendee.displayName
            )
        }

        return LocalAdmissionDecision.Accepted(
            attendeeId = attendee.id,
            displayName = attendee.displayName,
            ticketCode = canonicalTicketCode,
            idempotencyKey = idempotencyKey,
            scannedAt = scannedAt,
            localQueueId = insertedQueueId
        )
    }
}
