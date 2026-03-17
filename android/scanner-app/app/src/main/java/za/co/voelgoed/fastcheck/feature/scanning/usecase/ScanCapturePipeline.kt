package za.co.voelgoed.fastcheck.feature.scanning.usecase

import javax.inject.Inject
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import za.co.voelgoed.fastcheck.domain.usecase.QueueCapturedScanUseCase
import za.co.voelgoed.fastcheck.feature.scanning.analysis.DecodedBarcodeHandler
import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerCaptureDefaults

/**
 * CameraX and ML Kit hand decoded values into this pipeline only.
 * Queueing remains local-first and upload/flush stays outside scanner code.
 */
class ScanCapturePipeline @Inject constructor(
    private val queueCapturedScan: QueueCapturedScanUseCase,
    private val timeProvider: () -> Long = { System.currentTimeMillis() }
) : DecodedBarcodeHandler {

    private val _handoffResults =
        MutableSharedFlow<CaptureHandoffResult>(
            replay = 0,
            extraBufferCapacity = 16,
            onBufferOverflow = BufferOverflow.DROP_OLDEST
        )
    val handoffResults: SharedFlow<CaptureHandoffResult> = _handoffResults

    private var lastAcceptedAtEpochMillis: Long? = null

    override suspend fun onDecoded(rawValue: String) {
        val now = timeProvider.invoke()
        val lastAccepted = lastAcceptedAtEpochMillis

        if (lastAccepted != null && now - lastAccepted < COOLDOWN_WINDOW_MILLIS) {
            _handoffResults.tryEmit(CaptureHandoffResult.SuppressedByCooldown)
            return
        }

        try {
            queueCapturedScan.enqueue(
                ticketCode = rawValue,
                direction = ScannerCaptureDefaults.direction,
                operatorName = ScannerCaptureDefaults.operatorName,
                entranceName = ScannerCaptureDefaults.entranceName
            )
            lastAcceptedAtEpochMillis = now
            _handoffResults.tryEmit(CaptureHandoffResult.Accepted)
        } catch (t: Throwable) {
            val reason = t.message?.takeIf { it.isNotBlank() } ?: "Could not queue scan"
            _handoffResults.tryEmit(CaptureHandoffResult.Failed(reason))
        }
    }

    private companion object {
        const val COOLDOWN_WINDOW_MILLIS: Long = 1_000L
    }
}

