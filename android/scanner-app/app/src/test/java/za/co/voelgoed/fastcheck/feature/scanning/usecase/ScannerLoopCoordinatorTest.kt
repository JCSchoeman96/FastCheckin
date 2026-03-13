package za.co.voelgoed.fastcheck.feature.scanning.usecase

import com.google.common.truth.Truth.assertThat
import kotlinx.coroutines.launch
import kotlinx.coroutines.flow.take
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import org.junit.Test
import za.co.voelgoed.fastcheck.domain.model.QueueCreationResult
import za.co.voelgoed.fastcheck.domain.model.ScanDirection
import za.co.voelgoed.fastcheck.domain.usecase.QueueCapturedScanUseCase
import za.co.voelgoed.fastcheck.feature.scanning.analysis.ScannerFrameGate
import za.co.voelgoed.fastcheck.feature.scanning.domain.DecodedBarcode
import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerCaptureConfig
import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerCandidate
import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerResult

@OptIn(ExperimentalCoroutinesApi::class)
class ScannerLoopCoordinatorTest {
    @Test
    fun decodedBarcodeEmitsCandidateProcessingAndImmediateResultEventsInOrder() = runTest {
        val coordinator =
            ScannerLoopCoordinator(
                scanCapturePipeline =
                    ScanCapturePipeline(
                        queueCapturedScan = RecordingQueueCapturedScanUseCase(),
                        scannerCaptureConfig = ScannerCaptureConfig.default
                    ),
                scannerFrameGate = ScannerFrameGate()
            )
        val collectedEvents = mutableListOf<ScannerLoopEvent>()

        backgroundScope.launch(UnconfinedTestDispatcher(testScheduler)) {
            coordinator.events.take(3).toList(collectedEvents)
        }

        coordinator.onDecoded(DecodedBarcode(rawValue = "VG-500", capturedAtEpochMillis = 99L))
        advanceUntilIdle()

        assertThat(collectedEvents)
            .containsExactly(
                ScannerLoopEvent.CandidateAccepted(ScannerCandidate("VG-500", 99L)),
                ScannerLoopEvent.ProcessingStarted(ScannerCandidate("VG-500", 99L)),
                ScannerLoopEvent.ImmediateResult(
                    ScannerResult.ReplaySuppressed(ScannerCandidate("VG-500", 99L))
                )
            )
            .inOrder()
    }

    @Test
    fun cooldownCompleteReleasesFrameAdmission() {
        val gate = ScannerFrameGate()
        val coordinator =
            ScannerLoopCoordinator(
                scanCapturePipeline =
                    ScanCapturePipeline(
                        queueCapturedScan = RecordingQueueCapturedScanUseCase(),
                        scannerCaptureConfig = ScannerCaptureConfig.default
                    ),
                scannerFrameGate = gate
            )

        assertThat(
            gate.tryAdmit(
                za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerDetection(
                    rawValue = "VG-1",
                    bounds = null,
                    format = 1,
                    capturedAtEpochMillis = 1L
                )
            )
        ).isTrue()

        coordinator.onCooldownComplete()

        assertThat(
            gate.tryAdmit(
                za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerDetection(
                    rawValue = "VG-2",
                    bounds = null,
                    format = 1,
                    capturedAtEpochMillis = 2L
                )
            )
        ).isTrue()
    }

    private class RecordingQueueCapturedScanUseCase : QueueCapturedScanUseCase {
        override suspend fun enqueue(
            ticketCode: String,
            direction: ScanDirection,
            operatorName: String,
            entranceName: String
        ): QueueCreationResult = QueueCreationResult.ReplaySuppressed
    }
}
