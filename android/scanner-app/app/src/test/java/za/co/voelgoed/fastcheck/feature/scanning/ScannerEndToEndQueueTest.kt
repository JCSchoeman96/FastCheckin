package za.co.voelgoed.fastcheck.feature.scanning

import com.google.common.truth.Truth.assertThat
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import org.junit.Test
import za.co.voelgoed.fastcheck.domain.model.QueueCreationResult
import za.co.voelgoed.fastcheck.domain.model.ScanDirection
import za.co.voelgoed.fastcheck.domain.usecase.QueueCapturedScanUseCase
import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerCaptureDefaults
import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerCaptureEvent
import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerInputSource
import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerSourceState
import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerSourceType
import za.co.voelgoed.fastcheck.feature.scanning.usecase.ScanCapturePipeline
import za.co.voelgoed.fastcheck.feature.scanning.usecase.ScannerSourceBinding

class ScannerEndToEndQueueTest {

    @Test
    fun singleCaptureResultsInSingleEnqueueEvenUnderStartChurn() = runTest {
        val fakeSource = FakeScannerInputSource()
        val recordingUseCase = RecordingQueueCapturedScanUseCase()
        val pipeline = ScanCapturePipeline(recordingUseCase)
        val binding = ScannerSourceBinding(fakeSource, pipeline, this)

        // Redundant start calls from the shell should not create duplicate pipelines.
        binding.start()
        binding.start()
        advanceUntilIdle()

        fakeSource.emitCapture("VG-QUEUE-001")
        advanceUntilIdle()

        // Extra churn: stop and start again without emitting new captures.
        binding.stop()
        binding.start()
        advanceUntilIdle()

        assertThat(recordingUseCase.enqueueCallCount.get()).isEqualTo(1)
        assertThat(recordingUseCase.ticketCode).isEqualTo("VG-QUEUE-001")
        assertThat(recordingUseCase.direction).isEqualTo(ScanDirection.IN)
        assertThat(recordingUseCase.operatorName).isEqualTo(ScannerCaptureDefaults.operatorName)
        assertThat(recordingUseCase.entranceName).isEqualTo(ScannerCaptureDefaults.entranceName)

        // A second capture should increment enqueue count by exactly one.
        fakeSource.emitCapture("VG-QUEUE-002")
        advanceUntilIdle()

        assertThat(recordingUseCase.enqueueCallCount.get()).isEqualTo(2)
        assertThat(recordingUseCase.ticketCode).isEqualTo("VG-QUEUE-002")

        binding.stop()
    }

    private class FakeScannerInputSource : ScannerInputSource {

        private val _state = MutableStateFlow<ScannerSourceState>(ScannerSourceState.Idle)
        private val _captures = MutableSharedFlow<ScannerCaptureEvent>(extraBufferCapacity = 16)

        override val type: ScannerSourceType = ScannerSourceType.CAMERA
        override val id: String? = "fake-camera-queue"

        override val state: StateFlow<ScannerSourceState>
            get() = _state

        override val captures = _captures

        override fun start() {
            _state.value = ScannerSourceState.Starting
            _state.value = ScannerSourceState.Ready
        }

        override fun stop() {
            _state.value = ScannerSourceState.Stopping
            _state.value = ScannerSourceState.Idle
        }

        suspend fun emitCapture(rawValue: String) {
            _captures.emit(
                ScannerCaptureEvent(
                    rawValue = rawValue,
                    capturedAtEpochMillis = 1_700_000_000_000L,
                    sourceType = type,
                    sourceId = id
                )
            )
        }
    }

    private class RecordingQueueCapturedScanUseCase : QueueCapturedScanUseCase {
        val enqueueCallCount = AtomicInteger(0)
        var ticketCode: String? = null
        var direction: ScanDirection? = null
        var operatorName: String? = null
        var entranceName: String? = null

        override suspend fun enqueue(
            ticketCode: String,
            direction: ScanDirection,
            operatorName: String,
            entranceName: String
        ): QueueCreationResult {
            enqueueCallCount.incrementAndGet()
            this.ticketCode = ticketCode
            this.direction = direction
            this.operatorName = operatorName
            this.entranceName = entranceName
            return QueueCreationResult.ReplaySuppressed
        }
    }
}

