package za.co.voelgoed.fastcheck.feature.scanning.usecase

import javax.inject.Inject
import za.co.voelgoed.fastcheck.domain.usecase.QueueCapturedScanUseCase
import za.co.voelgoed.fastcheck.feature.scanning.analysis.DecodedBarcodeHandler
import za.co.voelgoed.fastcheck.feature.scanning.domain.DecodedBarcode
import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerCandidate
import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerCaptureConfig
import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerResult

/**
 * CameraX and ML Kit hand decoded values into this pipeline only.
 * Queueing remains local-first and upload/flush stays outside scanner code.
 */
class ScanCapturePipeline @Inject constructor(
    private val queueCapturedScan: QueueCapturedScanUseCase,
    private val scannerCaptureConfig: ScannerCaptureConfig
) : DecodedBarcodeHandler {
    override suspend fun onDecoded(decodedBarcode: DecodedBarcode) {
        val candidate = ScannerCandidate.fromDecoded(decodedBarcode) ?: return
        processCandidate(candidate)
    }

    suspend fun processCandidate(candidate: ScannerCandidate): ScannerResult {
        val queueResult =
            queueCapturedScan.enqueue(
                ticketCode = candidate.rawValue,
                direction = scannerCaptureConfig.direction,
                operatorName = scannerCaptureConfig.operatorName,
                entranceName = scannerCaptureConfig.entranceName
            )

        return ScannerResultMapper.fromQueueResult(candidate, queueResult)
    }
}
