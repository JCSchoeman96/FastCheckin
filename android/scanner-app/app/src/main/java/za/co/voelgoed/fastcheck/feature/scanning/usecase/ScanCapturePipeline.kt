package za.co.voelgoed.fastcheck.feature.scanning.usecase

import javax.inject.Inject
import kotlinx.coroutines.channels.BufferOverflow
import za.co.voelgoed.fastcheck.app.di.CurrentTimeProvider
import za.co.voelgoed.fastcheck.core.common.ScannerRuntimeLogger
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

    private var lastAcceptedAtEpochMillis: Long? = null

    override suspend fun onDecoded(rawValue: String) {
        val now = timeProvider.invoke()
        val lastAccepted = lastAcceptedAtEpochMillis
        ScannerRuntimeLogger.i(LOG_TAG, "handoff_received ticket=${maskTicketCode(rawValue)}")

        if (lastAccepted != null && now - lastAccepted < COOLDOWN_WINDOW_MILLIS) {
            ScannerRuntimeLogger.i(
                LOG_TAG,
                "handoff_suppressed_by_cooldown deltaMs=${now - lastAccepted}"
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
                    lastAcceptedAtEpochMillis = now
                    _handoffResults.tryEmit(
                        CaptureHandoffResult.Accepted(
                            attendeeId = decision.attendeeId,
                            displayName = decision.displayName,
                            ticketCode = decision.ticketCode,
                            idempotencyKey = decision.idempotencyKey,
                            scannedAt = decision.scannedAt
                        )
                    )
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

    private companion object {
        const val COOLDOWN_WINDOW_MILLIS: Long = 1_000L
        private const val LOG_TAG: String = "ScanCapturePipeline"
    }
}
