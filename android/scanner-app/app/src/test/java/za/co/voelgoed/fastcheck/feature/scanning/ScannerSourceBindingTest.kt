package za.co.voelgoed.fastcheck.feature.scanning

import com.google.common.truth.Truth.assertThat
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.advanceUntilIdle
import org.junit.Test
import za.co.voelgoed.fastcheck.feature.scanning.analysis.DecodedBarcodeHandler
import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerCaptureEvent
import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerInputSource
import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerSourceState
import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerSourceType
import za.co.voelgoed.fastcheck.feature.scanning.usecase.ScannerSourceBinding

class ScannerSourceBindingTest {

    @Test
    fun forwardsRawValuesUnchanged() = runTest {
        val fakeSource = FakeScannerInputSource()
        val recordingHandler = RecordingDecodedBarcodeHandler()
        val binding = ScannerSourceBinding(fakeSource, recordingHandler, this)

        binding.start()

        fakeSource.emitCapture("  VG-101  ")
        fakeSource.emitCapture("VG-102")

        advanceUntilIdle()

        assertThat(recordingHandler.values).containsExactly("  VG-101  ", "VG-102").inOrder()

        binding.stop()
    }

    @Test
    fun startIsIdempotentAndCallsSourceStartOnce() = runTest {
        val fakeSource = FakeScannerInputSource()
        val recordingHandler = RecordingDecodedBarcodeHandler()
        val binding = ScannerSourceBinding(fakeSource, recordingHandler, this)

        binding.start()
        binding.start()

        assertThat(fakeSource.startCallCount.get()).isEqualTo(1)

        binding.stop()
    }

    @Test
    fun stopIsIdempotentAndCallsSourceStopOncePerSession() = runTest {
        val fakeSource = FakeScannerInputSource()
        val recordingHandler = RecordingDecodedBarcodeHandler()
        val binding = ScannerSourceBinding(fakeSource, recordingHandler, this)

        binding.start()
        binding.stop()
        binding.stop()

        assertThat(fakeSource.stopCallCount.get()).isEqualTo(1)
    }

    @Test
    fun ignoresEventsAfterStop() = runTest {
        val fakeSource = FakeScannerInputSource()
        val recordingHandler = RecordingDecodedBarcodeHandler()
        val binding = ScannerSourceBinding(fakeSource, recordingHandler, this)

        binding.start()
        advanceUntilIdle()

        fakeSource.emitCapture("VG-101")
        advanceUntilIdle()

        binding.stop()
        advanceUntilIdle()

        fakeSource.emitCapture("VG-102")
        advanceUntilIdle()

        assertThat(recordingHandler.values).containsExactly("VG-101")
    }

    @Test
    fun restartAfterStopCreatesFreshBinding() = runTest {
        val fakeSource = FakeScannerInputSource()
        val recordingHandler = RecordingDecodedBarcodeHandler()
        val binding = ScannerSourceBinding(fakeSource, recordingHandler, this)

        binding.start()
        advanceUntilIdle()
        fakeSource.emitCapture("VG-101")
        advanceUntilIdle()

        binding.stop()
        advanceUntilIdle()

        binding.start()
        advanceUntilIdle()
        fakeSource.emitCapture("VG-102")
        advanceUntilIdle()

        assertThat(recordingHandler.values).containsExactly("VG-101", "VG-102").inOrder()
        assertThat(fakeSource.startCallCount.get()).isEqualTo(2)
        assertThat(fakeSource.stopCallCount.get()).isEqualTo(1)

        binding.stop()
    }

    @Test
    fun rapidStartStopSequencesDoNotCreateDuplicateForwardingPipelines() = runTest {
        val fakeSource = FakeScannerInputSource()
        val recordingHandler = RecordingDecodedBarcodeHandler()
        val binding = ScannerSourceBinding(fakeSource, recordingHandler, this)

        // Rapid lifecycle churn: start/stop/start/stop before and after captures.
        binding.start()
        binding.start()
        advanceUntilIdle()

        fakeSource.emitCapture("VG-201")
        advanceUntilIdle()

        binding.stop()
        binding.stop()
        advanceUntilIdle()

        binding.start()
        binding.start()
        advanceUntilIdle()

        fakeSource.emitCapture("VG-202")
        advanceUntilIdle()

        binding.stop()

        assertThat(recordingHandler.values).containsExactly("VG-201", "VG-202").inOrder()
        // Under churn we still expect one logical start/stop session per phase.
        assertThat(fakeSource.startCallCount.get()).isEqualTo(2)
        assertThat(fakeSource.stopCallCount.get()).isEqualTo(2)
    }

    @Test
    fun permissionAndShellGatingStartBindingExactlyOnceAndForwardSingleCapture() = runTest {
        val fakeSource = FakeScannerInputSource()
        val recordingHandler = RecordingDecodedBarcodeHandler()
        val binding = ScannerSourceBinding(fakeSource, recordingHandler, this)

        var hasPermission = false
        var isShellActive = true

        fun evaluateShellStartIfNeeded() {
            if (isShellActive && hasPermission) {
                binding.start()
            }
        }

        // Shell becomes active without permission; binding must not start.
        evaluateShellStartIfNeeded()
        evaluateShellStartIfNeeded()
        advanceUntilIdle()

        assertThat(fakeSource.startCallCount.get()).isEqualTo(0)
        assertThat(recordingHandler.values).isEmpty()

        // Permission granted while shell is still active; binding starts exactly once.
        hasPermission = true
        evaluateShellStartIfNeeded()
        advanceUntilIdle()

        assertThat(fakeSource.startCallCount.get()).isEqualTo(1)

        // Re-evaluating active+permission logic must not trigger extra starts.
        repeat(3) {
            evaluateShellStartIfNeeded()
        }
        advanceUntilIdle()

        assertThat(fakeSource.startCallCount.get()).isEqualTo(1)

        // A single capture is forwarded exactly once.
        fakeSource.emitCapture("VG-PERM-001")
        advanceUntilIdle()

        assertThat(recordingHandler.values).containsExactly("VG-PERM-001")

        binding.stop()
    }

    @Test
    fun exposesUnderlyingSourceStateDirectly() = runTest {
        val fakeSource = FakeScannerInputSource()
        val recordingHandler = RecordingDecodedBarcodeHandler()
        val binding = ScannerSourceBinding(fakeSource, recordingHandler, this)

        assertThat(binding.sourceState.value).isEqualTo(ScannerSourceState.Idle)

        fakeSource.setState(ScannerSourceState.Starting)
        assertThat(binding.sourceState.value).isEqualTo(ScannerSourceState.Starting)

        fakeSource.setState(ScannerSourceState.Ready)
        assertThat(binding.sourceState.value).isEqualTo(ScannerSourceState.Ready)
    }

    @Test
    fun cleansUpWhenSourceStartThrows() = runTest {
        val throwingSource = ThrowingStartScannerInputSource()
        val recordingHandler = RecordingDecodedBarcodeHandler()
        val binding = ScannerSourceBinding(throwingSource, recordingHandler, this)

        var thrown: Throwable? = null
        try {
            binding.start()
        } catch (t: Throwable) {
            thrown = t
        }

        assertThat(thrown).isNotNull()

        // Subsequent start attempts should still be possible.
        throwingSource.shouldThrowOnStart = false
        binding.start()
        throwingSource.emitCapture("VG-103")

        advanceUntilIdle()

        assertThat(recordingHandler.values).containsExactly("VG-103")

        binding.stop()
    }

    private class FakeScannerInputSource : ScannerInputSource {

        private val _state = MutableStateFlow<ScannerSourceState>(ScannerSourceState.Idle)
        private val _captures = MutableSharedFlow<ScannerCaptureEvent>(extraBufferCapacity = 16)

        val startCallCount = AtomicInteger(0)
        val stopCallCount = AtomicInteger(0)

        override val type = ScannerSourceType.CAMERA
        override val id: String? = "fake-camera-0"

        override val state: StateFlow<ScannerSourceState>
            get() = _state

        override val captures = _captures

        override fun start() {
            startCallCount.incrementAndGet()
        }

        override fun stop() {
            stopCallCount.incrementAndGet()
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

        fun setState(state: ScannerSourceState) {
            _state.value = state
        }
    }

    private class ThrowingStartScannerInputSource : ScannerInputSource {

        private val _state = MutableStateFlow<ScannerSourceState>(ScannerSourceState.Idle)
        private val _captures = MutableSharedFlow<ScannerCaptureEvent>(extraBufferCapacity = 16)

        var shouldThrowOnStart: Boolean = true

        override val type = ScannerSourceType.CAMERA
        override val id: String? = "throwing-camera"

        override val state: StateFlow<ScannerSourceState>
            get() = _state

        override val captures = _captures

        override fun start() {
            if (shouldThrowOnStart) {
                throw IllegalStateException("Failed to start source")
            }
        }

        override fun stop() {
            // no-op for this fake
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

    private class RecordingDecodedBarcodeHandler : DecodedBarcodeHandler {
        private val _values = mutableListOf<String>()
        val values: List<String> get() = _values

        override suspend fun onDecoded(rawValue: String) {
            _values.add(rawValue)
        }
    }
}

