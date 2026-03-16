package za.co.voelgoed.fastcheck.feature.scanning.usecase

import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import za.co.voelgoed.fastcheck.feature.scanning.analysis.DecodedBarcodeHandler
import za.co.voelgoed.fastcheck.feature.scanning.analysis.ScannerFrameGate
import za.co.voelgoed.fastcheck.feature.scanning.domain.DecodedBarcode
import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerCandidate

@Singleton
class ScannerLoopCoordinator @Inject constructor(
    private val scanCapturePipeline: ScanCapturePipeline,
    private val scannerFrameGate: ScannerFrameGate
) : DecodedBarcodeHandler, ScannerLoopController {
    private val _events = MutableSharedFlow<ScannerLoopEvent>(extraBufferCapacity = 8)
    override val events: SharedFlow<ScannerLoopEvent> = _events.asSharedFlow()

    override suspend fun onDecoded(decodedBarcode: DecodedBarcode) {
        val candidate = ScannerCandidate.fromDecoded(decodedBarcode) ?: return

        _events.emit(ScannerLoopEvent.CandidateAccepted(candidate))
        _events.emit(ScannerLoopEvent.ProcessingStarted(candidate))
        _events.emit(ScannerLoopEvent.ImmediateResult(scanCapturePipeline.processCandidate(candidate)))
    }

    override fun reset() {
        scannerFrameGate.reset()
    }

    override fun onCooldownComplete() {
        scannerFrameGate.release()
    }
}
