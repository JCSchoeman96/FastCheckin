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
    private val queueCapturedScan: QueueCapturedScanUseCase
) : DecodedBarcodeHandler {

    private val _handoffResults =
        MutableSharedFlow<CaptureHandoffResult>(
            replay = 0,
            extraBufferCapacity = 16,
            onBufferOverflow = BufferOverflow.DROP_OLDEST
        )
    val handoffResults: SharedFlow<CaptureHandoffResult> = _handoffResults

    override suspend fun onDecoded(rawValue: String) {
        try {
            queueCapturedScan.enqueue(
                ticketCode = rawValue,
                direction = ScannerCaptureDefaults.direction,
                operatorName = ScannerCaptureDefaults.operatorName,
                entranceName = ScannerCaptureDefaults.entranceName
            )
            _handoffResults.tryEmit(CaptureHandoffResult.Accepted)
        } catch (t: Throwable) {
            val reason = t.message?.takeIf { it.isNotBlank() } ?: "Could not queue scan"
            _handoffResults.tryEmit(CaptureHandoffResult.Failed(reason))
        }
    }
}
