package za.co.voelgoed.fastcheck.feature.scanning

import com.google.common.truth.Truth.assertThat
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.test.runTest
import org.junit.Test
import za.co.voelgoed.fastcheck.core.network.PhoenixMobileApi
import za.co.voelgoed.fastcheck.data.remote.PhoenixMobileRemoteDataSource
import za.co.voelgoed.fastcheck.data.repository.MobileScanRepository
import za.co.voelgoed.fastcheck.domain.model.QueueCreationResult
import za.co.voelgoed.fastcheck.domain.model.ScanDirection
import za.co.voelgoed.fastcheck.domain.usecase.QueueCapturedScanUseCase
import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerCaptureDefaults
import za.co.voelgoed.fastcheck.feature.scanning.usecase.CaptureHandoffResult
import za.co.voelgoed.fastcheck.feature.scanning.usecase.ScanCapturePipeline

class ScanCapturePipelineTest {
    @Test
    fun handsDecodedValueToLocalQueueWithScannerDefaults() = runTest {
        val fakeUseCase = RecordingQueueCapturedScanUseCase()
        val pipeline = ScanCapturePipeline(fakeUseCase) { 0L }

        pipeline.onDecoded("  VG-101  ")

        assertThat(fakeUseCase.ticketCode).isEqualTo("  VG-101  ")
        assertThat(fakeUseCase.direction).isEqualTo(ScanDirection.IN)
        assertThat(fakeUseCase.operatorName).isEqualTo(ScannerCaptureDefaults.operatorName)
        assertThat(fakeUseCase.entranceName).isEqualTo(ScannerCaptureDefaults.entranceName)
    }

    @Test
    fun doesNotExposeDirectNetworkDependenciesAtAnalyzerBoundary() {
        val constructorParameterTypes =
            ScanCapturePipeline::class.java.declaredConstructors.single().parameterTypes.toList()

        assertThat(constructorParameterTypes).contains(QueueCapturedScanUseCase::class.java)
        assertThat(constructorParameterTypes).doesNotContain(PhoenixMobileApi::class.java)
        assertThat(constructorParameterTypes).doesNotContain(PhoenixMobileRemoteDataSource::class.java)
        assertThat(constructorParameterTypes).doesNotContain(MobileScanRepository::class.java)
    }

    @Test
    fun firstCaptureAccepted_secondSameCodeWithinWindowSuppressed() = runTest {
        val fakeUseCase = RecordingQueueCapturedScanUseCase()
        var now = 1_000L
        val pipeline = ScanCapturePipeline(fakeUseCase) { now }

        val firstResult = async(start = CoroutineStart.UNDISPATCHED) { pipeline.handoffResults.first() }
        pipeline.onDecoded("CODE-A")
        val first = firstResult.await()

        now += 500L
        val secondResult = async(start = CoroutineStart.UNDISPATCHED) { pipeline.handoffResults.first() }
        pipeline.onDecoded("CODE-A")
        val second = secondResult.await()

        assertThat(fakeUseCase.enqueueCallCount).isEqualTo(1)
        assertThat(first).isEqualTo(CaptureHandoffResult.Accepted)
        assertThat(second).isEqualTo(CaptureHandoffResult.SuppressedByCooldown)
    }

    @Test
    fun differentCodeWithinWindowIsAlsoSuppressed() = runTest {
        val fakeUseCase = RecordingQueueCapturedScanUseCase()
        var now = 5_000L
        val pipeline = ScanCapturePipeline(fakeUseCase) { now }

        val firstResult = async(start = CoroutineStart.UNDISPATCHED) { pipeline.handoffResults.first() }
        pipeline.onDecoded("CODE-A")
        val first = firstResult.await()

        now += 500L
        val secondResult = async(start = CoroutineStart.UNDISPATCHED) { pipeline.handoffResults.first() }
        pipeline.onDecoded("CODE-B")
        val second = secondResult.await()

        assertThat(fakeUseCase.enqueueCallCount).isEqualTo(1)
        assertThat(first).isEqualTo(CaptureHandoffResult.Accepted)
        assertThat(second).isEqualTo(CaptureHandoffResult.SuppressedByCooldown)
    }

    @Test
    fun captureAfterCooldownExpiryIsAcceptedAgain() = runTest {
        val fakeUseCase = RecordingQueueCapturedScanUseCase()
        var now = 10_000L
        val pipeline = ScanCapturePipeline(fakeUseCase) { now }

        val firstResult = async(start = CoroutineStart.UNDISPATCHED) { pipeline.handoffResults.first() }
        pipeline.onDecoded("CODE-A")
        val first = firstResult.await()

        now += 2_000L
        val secondResult = async(start = CoroutineStart.UNDISPATCHED) { pipeline.handoffResults.first() }
        pipeline.onDecoded("CODE-B")
        val second = secondResult.await()

        assertThat(fakeUseCase.enqueueCallCount).isEqualTo(2)
        assertThat(first).isEqualTo(CaptureHandoffResult.Accepted)
        assertThat(second).isEqualTo(CaptureHandoffResult.Accepted)
    }

    private class RecordingQueueCapturedScanUseCase : QueueCapturedScanUseCase {
        var enqueueCallCount: Int = 0
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
            enqueueCallCount += 1
            this.ticketCode = ticketCode
            this.direction = direction
            this.operatorName = operatorName
            this.entranceName = entranceName
            return QueueCreationResult.ReplaySuppressed
        }
    }
}
