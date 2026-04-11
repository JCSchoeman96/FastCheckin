package za.co.voelgoed.fastcheck.domain.usecase

import java.time.Clock
import java.time.Instant
import java.util.UUID
import javax.inject.Inject
import kotlinx.coroutines.withTimeoutOrNull
import za.co.voelgoed.fastcheck.core.connectivity.ConnectivityMonitor
import za.co.voelgoed.fastcheck.core.sync.AttendeeSyncOrchestrator
import za.co.voelgoed.fastcheck.core.ticket.TicketCodeNormalizer
import za.co.voelgoed.fastcheck.core.common.ScannerRuntimeLogger
import za.co.voelgoed.fastcheck.data.local.LocalAdmissionOverlayEntity
import za.co.voelgoed.fastcheck.data.local.QueuedScanEntity
import za.co.voelgoed.fastcheck.data.local.ScannerDao
import za.co.voelgoed.fastcheck.data.repository.AttendeeSyncMode
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
import za.co.voelgoed.fastcheck.domain.policy.AdmissionCacheReadiness
import za.co.voelgoed.fastcheck.domain.policy.AttendeeSyncBootstrapGate
import za.co.voelgoed.fastcheck.domain.policy.CurrentEventAdmissionReadiness

class DefaultAdmitScanUseCase @Inject constructor(
    private val attendeeLookupRepository: AttendeeLookupRepository,
    private val scannerDao: ScannerDao,
    private val sessionAuthGateway: SessionAuthGateway,
    private val syncRepository: SyncRepository,
    private val paymentStatusRuleMapper: PaymentStatusRuleMapper,
    private val currentEventAdmissionReadiness: CurrentEventAdmissionReadiness,
    private val attendeeSyncBootstrapGate: AttendeeSyncBootstrapGate,
    private val connectivityMonitor: ConnectivityMonitor,
    private val attendeeSyncOrchestrator: AttendeeSyncOrchestrator,
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
                ).also {
                    ScannerRuntimeLogger.i(
                        LOG_TAG,
                        "admit_result type=invalid_ticket_code ticket=${maskTicketCode(ticketCode)}"
                    )
                }
        ScannerRuntimeLogger.i(LOG_TAG, "admit_started ticket=${maskTicketCode(canonicalTicketCode)}")

        val eventId =
            sessionAuthGateway.currentEventId()
                ?: return LocalAdmissionDecision.ReviewRequired(
                    reason = LocalAdmissionReviewReason.MissingSessionContext,
                    displayMessage = "Login is required before local admission can continue.",
                    ticketCode = canonicalTicketCode
                ).also {
                    ScannerRuntimeLogger.i(
                        LOG_TAG,
                        "admit_result type=missing_session_context ticket=${maskTicketCode(canonicalTicketCode)}"
                    )
                }
        ScannerRuntimeLogger.d(LOG_TAG, "admit_context eventId=$eventId")

        val syncStatus = syncRepository.currentSyncStatus()
        val bootstrapInFlight =
            attendeeSyncBootstrapGate.isInitialBootstrapSyncInProgressForEvent(eventId)
        val readiness =
            currentEventAdmissionReadiness.evaluateReadiness(
                eventId = eventId,
                syncStatus = syncStatus,
                bootstrapSyncInProgress = bootstrapInFlight
            )

        if (readiness.readiness == AdmissionCacheReadiness.NOT_READY_UNSAFE) {
            return LocalAdmissionDecision.ReviewRequired(
                reason = LocalAdmissionReviewReason.CacheNotTrusted,
                displayMessage =
                    "Attendee list is not ready for this event yet. " +
                        "Wait for sync to finish or use manual review.",
                ticketCode = canonicalTicketCode
            ).also {
                ScannerRuntimeLogger.i(
                    LOG_TAG,
                    "admit_result type=cache_not_trusted eventId=$eventId ticket=${maskTicketCode(canonicalTicketCode)}"
                )
            }
        }

        var attendee =
            attendeeLookupRepository.findByTicketCode(eventId, canonicalTicketCode)

        if (attendee == null && readiness.readiness == AdmissionCacheReadiness.READY_STALE) {
            attendeeSyncOrchestrator.notifyStaleScanRefreshAdvisory()
            if (connectivityMonitor.isOnline.value) {
                withTimeoutOrNull(SCAN_ASSIST_TIMEOUT_MS) {
                    syncRepository.syncAttendees(AttendeeSyncMode.INCREMENTAL)
                }
            }
            attendee =
                attendeeLookupRepository.findByTicketCode(eventId, canonicalTicketCode)
        }

        if (attendee == null) {
            if (readiness.readiness == AdmissionCacheReadiness.READY_STALE) {
                ScannerRuntimeLogger.i(
                    LOG_TAG,
                    "admit_result type=local_attendee_missing eventId=$eventId ticket=${maskTicketCode(canonicalTicketCode)}"
                )
                return LocalAdmissionDecision.ReviewRequired(
                    reason = LocalAdmissionReviewReason.TicketNotInLocalAttendeeList,
                    displayMessage = "Ticket not in saved attendee list.",
                    ticketCode = canonicalTicketCode
                )
            }

            return LocalAdmissionDecision.Rejected(
                reason = LocalAdmissionRejectReason.TicketNotFound,
                displayMessage = "Invalid scan. Ticket not found for this event.",
                ticketCode = canonicalTicketCode
            ).also {
                ScannerRuntimeLogger.i(
                    LOG_TAG,
                    "admit_result type=ticket_not_found eventId=$eventId ticket=${maskTicketCode(canonicalTicketCode)}"
                )
            }
        }

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
            ).also {
                ScannerRuntimeLogger.i(
                    LOG_TAG,
                    "admit_result type=conflict_requires_resolution eventId=$eventId ticket=${maskTicketCode(canonicalTicketCode)}"
                )
            }
        }

        if (readiness.readiness == AdmissionCacheReadiness.READY_STALE) {
            attendeeSyncOrchestrator.notifyStaleScanRefreshAdvisory()
        }

        if (attendee.isCurrentlyInside) {
            return LocalAdmissionDecision.Rejected(
                reason = LocalAdmissionRejectReason.AlreadyInside,
                displayMessage = "Invalid scan. This attendee is already inside.",
                ticketCode = canonicalTicketCode,
                displayName = attendee.displayName
            ).also {
                ScannerRuntimeLogger.i(
                    LOG_TAG,
                    "admit_result type=already_inside eventId=$eventId ticket=${maskTicketCode(canonicalTicketCode)}"
                )
            }
        }

        if (attendee.checkinsRemaining <= 0) {
            return LocalAdmissionDecision.Rejected(
                reason = LocalAdmissionRejectReason.NoCheckinsRemaining,
                displayMessage = "Invalid scan. No check-ins remain for this attendee.",
                ticketCode = canonicalTicketCode,
                displayName = attendee.displayName
            ).also {
                ScannerRuntimeLogger.i(
                    LOG_TAG,
                    "admit_result type=no_checkins_remaining eventId=$eventId ticket=${maskTicketCode(canonicalTicketCode)}"
                )
            }
        }

        when (paymentStatusRuleMapper.map(attendee.paymentStatus)) {
            PaymentStatusDecision.BLOCKED ->
                return LocalAdmissionDecision.Rejected(
                    reason = LocalAdmissionRejectReason.PaymentBlocked,
                    displayMessage = "Invalid scan. Payment status does not allow admission.",
                    ticketCode = canonicalTicketCode,
                    displayName = attendee.displayName
                ).also {
                    ScannerRuntimeLogger.i(
                        LOG_TAG,
                        "admit_result type=payment_blocked eventId=$eventId ticket=${maskTicketCode(canonicalTicketCode)}"
                    )
                }

            PaymentStatusDecision.UNKNOWN ->
                return LocalAdmissionDecision.ReviewRequired(
                    reason = LocalAdmissionReviewReason.PaymentUnknown,
                    displayMessage = "Payment status needs manual review before admission.",
                    ticketCode = canonicalTicketCode,
                    displayName = attendee.displayName
                ).also {
                    ScannerRuntimeLogger.i(
                        LOG_TAG,
                        "admit_result type=payment_unknown eventId=$eventId ticket=${maskTicketCode(canonicalTicketCode)}"
                    )
                }

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
            ).also {
                ScannerRuntimeLogger.i(
                    LOG_TAG,
                    "admit_result type=replay_suppressed eventId=$eventId ticket=${maskTicketCode(canonicalTicketCode)}"
                )
            }
        }

        if (insertedQueueId <= 0L) {
            return LocalAdmissionDecision.ReviewRequired(
                reason = LocalAdmissionReviewReason.LocalWriteFailed,
                displayMessage = "Local admission could not be written safely. Manual review is required.",
                ticketCode = canonicalTicketCode,
                displayName = attendee.displayName
            ).also {
                ScannerRuntimeLogger.w(
                    LOG_TAG,
                    "admit_result type=local_write_failed eventId=$eventId ticket=${maskTicketCode(canonicalTicketCode)}"
                )
            }
        }

        return LocalAdmissionDecision.Accepted(
            attendeeId = attendee.id,
            displayName = attendee.displayName,
            ticketCode = canonicalTicketCode,
            idempotencyKey = idempotencyKey,
            scannedAt = scannedAt,
            localQueueId = insertedQueueId
        ).also {
            ScannerRuntimeLogger.i(
                LOG_TAG,
                "admit_result type=accepted eventId=$eventId ticket=${maskTicketCode(canonicalTicketCode)}"
            )
        }
    }

    private fun maskTicketCode(ticketCode: String): String {
        val trimmed = ticketCode.trim()
        if (trimmed.length <= 4) return "***$trimmed"
        return "***${trimmed.takeLast(4)}"
    }

    private companion object {
        private const val LOG_TAG: String = "DefaultAdmitScan"
        private const val SCAN_ASSIST_TIMEOUT_MS: Long = 250L
    }
}
