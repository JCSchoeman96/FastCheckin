package za.co.voelgoed.fastcheck.feature.scanning.usecase

import javax.inject.Inject
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
    override suspend fun onDecoded(rawValue: String) {
        queueCapturedScan.enqueue(
            ticketCode = rawValue,
            direction = ScannerCaptureDefaults.direction,
            operatorName = ScannerCaptureDefaults.operatorName,
            entranceName = ScannerCaptureDefaults.entranceName
        )
    }
}
