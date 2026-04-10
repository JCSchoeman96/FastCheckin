package za.co.voelgoed.fastcheck.feature.scanning.usecase

import javax.inject.Inject
import kotlinx.coroutines.channels.BufferOverflow
import za.co.voelgoed.fastcheck.app.di.CurrentTimeProvider
import za.co.voelgoed.fastcheck.core.common.ScannerRuntimeLogger
import za.co.voelgoed.fastcheck.core.ticket.TicketCodeNormalizer
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import za.co.voelgoed.fastcheck.domain.model.LocalAdmissionDecision
import za.co.voelgoed.fastcheck.domain.usecase.AdmitScanUseCase
import za.co.voelgoed.fastcheck.feature.scanning.analysis.DecodeDiagnostic
import za.co.voelgoed.fastcheck.feature.scanning.analysis.DecodedBarcodeHandler
import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerCaptureDefaults

/**
 * CameraX and ML Kit hand decoded values into this pipeline only.
 * Local gate decisions stay local-first and upload/flush stays outside scanner code.
 */
class ScanCapturePipeline @Inject constructor(
    private val admitScanUseCase: AdmitScanUseCase,
    @CurrentTimeProvider private val timeProvider: () -> Long
) : DecodedBarcodeHandler {

    private val _handoffResults =
        MutableSharedFlow<CaptureHandoffResult>(
            replay = 0,
            extraBufferCapacity = 16,
            onBufferOverflow = BufferOverflow.DROP_OLDEST
        )
    val handoffResults: SharedFlow<CaptureHandoffResult> = _handoffResults
    private val _decodeDiagnostics =
        MutableSharedFlow<DecodeDiagnostic>(
            replay = 1,
            extraBufferCapacity = 16,
            onBufferOverflow = BufferOverflow.DROP_OLDEST
        )
    val decodeDiagnostics: SharedFlow<DecodeDiagnostic> = _decodeDiagnostics

    private val suppressedTicketsByEpochMillis: MutableMap<String, Long> = mutableMapOf()

    override suspend fun onDecoded(rawValue: String) {
        val now = timeProvider.invoke()
        val suppressionKey = TicketCodeNormalizer.normalizeOrNull(rawValue) ?: rawValue.trim()
        ScannerRuntimeLogger.i(LOG_TAG, "handoff_received ticket=${maskTicketCode(rawValue)}")

        pruneExpiredSuppressionEntries(now)
        val lastProcessedAt = suppressedTicketsByEpochMillis[suppressionKey]
        if (lastProcessedAt != null && now - lastProcessedAt < SAME_TICKET_SUPPRESSION_WINDOW_MILLIS) {
            ScannerRuntimeLogger.i(
                LOG_TAG,
                "handoff_suppressed_same_ticket deltaMs=${now - lastProcessedAt} ticket=${maskTicketCode(suppressionKey)}"
            )
            _handoffResults.tryEmit(CaptureHandoffResult.SuppressedByCooldown)
            return
        }

        try {
            when (
                val decision =
                    admitScanUseCase.admit(
                        ticketCode = rawValue,
                        direction = ScannerCaptureDefaults.direction,
                        operatorName = ScannerCaptureDefaults.operatorName,
                        entranceName = ScannerCaptureDefaults.entranceName
                    )
            ) {
                is LocalAdmissionDecision.Accepted -> {
                    ScannerRuntimeLogger.i(
                        LOG_TAG,
                        "admit_decision type=accepted ticket=${maskTicketCode(decision.ticketCode)}"
                    )
                    _handoffResults.tryEmit(
                        CaptureHandoffResult.Accepted(
                            attendeeId = decision.attendeeId,
                            displayName = decision.displayName,
                            ticketCode = decision.ticketCode,
                            idempotencyKey = decision.idempotencyKey,
                            scannedAt = decision.scannedAt
                        )
                    )
                    suppressedTicketsByEpochMillis[suppressionKey] = now
                }

                is LocalAdmissionDecision.Rejected ->
                    ScannerRuntimeLogger.i(
                        LOG_TAG,
                        "admit_decision type=rejected ticket=${maskTicketCode(decision.ticketCode)}"
                    ).let {
                        _handoffResults.tryEmit(
                            CaptureHandoffResult.Rejected(
                                reason = decision.displayMessage,
                                ticketCode = decision.ticketCode,
                                displayName = decision.displayName
                            )
                        )
                        suppressedTicketsByEpochMillis[suppressionKey] = now
                    }

                is LocalAdmissionDecision.ReviewRequired ->
                    ScannerRuntimeLogger.i(
                        LOG_TAG,
                        "admit_decision type=review_required ticket=${maskTicketCode(decision.ticketCode)}"
                    ).let {
                        _handoffResults.tryEmit(
                            CaptureHandoffResult.ReviewRequired(
                                reason = decision.displayMessage,
                                ticketCode = decision.ticketCode,
                                displayName = decision.displayName
                            )
                        )
                        suppressedTicketsByEpochMillis[suppressionKey] = now
                    }

                is LocalAdmissionDecision.OperationalFailure ->
                    ScannerRuntimeLogger.w(LOG_TAG, "admit_decision type=operational_failure").let {
                        _handoffResults.tryEmit(CaptureHandoffResult.Failed(decision.displayMessage))
                    }
            }
        } catch (t: Throwable) {
            ScannerRuntimeLogger.e(LOG_TAG, "handoff_failed message=${t.message}", t)
            val reason = t.message?.takeIf { it.isNotBlank() } ?: "Could not queue scan"
            _handoffResults.tryEmit(CaptureHandoffResult.Failed(reason))
        }
    }

    override fun onDecodeDiagnostic(diagnostic: DecodeDiagnostic) {
        _decodeDiagnostics.tryEmit(diagnostic)
    }

    private fun maskTicketCode(ticketCode: String): String {
        val trimmed = ticketCode.trim()
        if (trimmed.length <= 4) return "***$trimmed"
        return "***${trimmed.takeLast(4)}"
    }

    private fun pruneExpiredSuppressionEntries(now: Long) {
        suppressedTicketsByEpochMillis.entries.removeIf { (_, seenAt) ->
            now - seenAt >= SAME_TICKET_SUPPRESSION_WINDOW_MILLIS
        }
    }

    private companion object {
        const val SAME_TICKET_SUPPRESSION_WINDOW_MILLIS: Long = 10_000L
        private const val LOG_TAG: String = "ScanCapturePipeline"
    }
}
