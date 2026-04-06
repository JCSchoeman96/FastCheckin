package za.co.voelgoed.fastcheck.feature.scanning

import com.google.common.truth.Truth.assertThat
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import org.junit.Test
import za.co.voelgoed.fastcheck.domain.model.LocalAdmissionDecision
import za.co.voelgoed.fastcheck.domain.model.ScanDirection
import za.co.voelgoed.fastcheck.domain.usecase.AdmitScanUseCase
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
        val recordingUseCase = RecordingAdmitScanUseCase()
        var now = 1_000L
        val pipeline = ScanCapturePipeline(recordingUseCase) { now }
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
        now += 2_000L
        fakeSource.emitCapture("VG-QUEUE-002")
        advanceUntilIdle()

        assertThat(recordingUseCase.enqueueCallCount.get()).isEqualTo(2)
        assertThat(recordingUseCase.ticketCode).isEqualTo("VG-QUEUE-002")

        binding.stop()
    }

    @Test
    fun broadcastCaptureUsesSameQueueAndCooldownSemantics() = runTest {
        val fakeSource = FakeScannerInputSource(type = ScannerSourceType.BROADCAST_INTENT)
        val recordingUseCase = RecordingAdmitScanUseCase()
        var now = 10_000L
        val pipeline = ScanCapturePipeline(recordingUseCase) { now }
        val binding = ScannerSourceBinding(fakeSource, pipeline, this)

        binding.start()
        advanceUntilIdle()

        fakeSource.emitCapture("VG-DW-QUEUE-001")
        advanceUntilIdle()

        now += 500L
        fakeSource.emitCapture("VG-DW-QUEUE-001")
        advanceUntilIdle()

        now += 2_000L
        fakeSource.emitCapture("VG-DW-QUEUE-002")
        advanceUntilIdle()

        assertThat(recordingUseCase.enqueueCallCount.get()).isEqualTo(2)
        assertThat(recordingUseCase.ticketCode).isEqualTo("VG-DW-QUEUE-002")

        binding.stop()
    }

    private class FakeScannerInputSource(
        override val type: ScannerSourceType = ScannerSourceType.CAMERA
    ) : ScannerInputSource {

        private val _state = MutableStateFlow<ScannerSourceState>(ScannerSourceState.Idle)
        private val _captures = MutableSharedFlow<ScannerCaptureEvent>(extraBufferCapacity = 16)

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

    private class RecordingAdmitScanUseCase : AdmitScanUseCase {
        val enqueueCallCount = AtomicInteger(0)
        var ticketCode: String? = null
        var direction: ScanDirection? = null
        var operatorName: String? = null
        var entranceName: String? = null

        override suspend fun admit(
            ticketCode: String,
            direction: ScanDirection,
            operatorName: String,
            entranceName: String
        ): LocalAdmissionDecision {
            enqueueCallCount.incrementAndGet()
            this.ticketCode = ticketCode
            this.direction = direction
            this.operatorName = operatorName
            this.entranceName = entranceName
            return LocalAdmissionDecision.Accepted(
                attendeeId = 1L,
                displayName = "Queue Test",
                ticketCode = ticketCode,
                idempotencyKey = "idem-$ticketCode",
                scannedAt = "2026-04-06T10:00:00Z",
                localQueueId = enqueueCallCount.get().toLong()
            )
        }
    }
}
