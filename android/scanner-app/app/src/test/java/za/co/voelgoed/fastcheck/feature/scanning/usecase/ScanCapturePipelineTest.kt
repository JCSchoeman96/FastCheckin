package za.co.voelgoed.fastcheck.feature.scanning.usecase

import com.google.common.truth.Truth.assertThat
import kotlinx.coroutines.test.runTest
import org.junit.Test
import za.co.voelgoed.fastcheck.core.network.PhoenixMobileApi
import za.co.voelgoed.fastcheck.data.remote.PhoenixMobileRemoteDataSource
import za.co.voelgoed.fastcheck.data.repository.MobileScanRepository
import za.co.voelgoed.fastcheck.domain.model.QueueCreationResult
import za.co.voelgoed.fastcheck.domain.model.ScanDirection
import za.co.voelgoed.fastcheck.domain.usecase.QueueCapturedScanUseCase
import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerCandidate
import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerCaptureConfig
import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerResult

class ScanCapturePipelineTest {
    private val scannerCaptureConfig = ScannerCaptureConfig.default

    @Test
    fun handsDecodedValueToLocalQueueWithScannerConfigPreservingRawValue() = runTest {
        val fakeUseCase = RecordingQueueCapturedScanUseCase()
        val pipeline = ScanCapturePipeline(fakeUseCase, scannerCaptureConfig)

        pipeline.processCandidate(ScannerCandidate(rawValue = "  VG-101  ", capturedAtEpochMillis = 1L))

        assertThat(fakeUseCase.ticketCode).isEqualTo("  VG-101  ")
        assertThat(fakeUseCase.direction).isEqualTo(ScanDirection.IN)
        assertThat(fakeUseCase.operatorName).isEqualTo(scannerCaptureConfig.operatorName)
        assertThat(fakeUseCase.entranceName).isEqualTo(scannerCaptureConfig.entranceName)
    }

    @Test
    fun doesNotExposeDirectNetworkDependenciesAtAnalyzerBoundary() {
        val constructorParameterTypes =
            ScanCapturePipeline::class.java.declaredConstructors.single().parameterTypes.toList()

        assertThat(constructorParameterTypes)
            .containsExactly(QueueCapturedScanUseCase::class.java, ScannerCaptureConfig::class.java)
        assertThat(constructorParameterTypes).doesNotContain(PhoenixMobileApi::class.java)
        assertThat(constructorParameterTypes).doesNotContain(PhoenixMobileRemoteDataSource::class.java)
        assertThat(constructorParameterTypes).doesNotContain(MobileScanRepository::class.java)
    }

    @Test
    fun mapsQueueOutcomeIntoScannerLocalResult() = runTest {
        val fakeUseCase = RecordingQueueCapturedScanUseCase()
        val pipeline = ScanCapturePipeline(fakeUseCase, scannerCaptureConfig)

        val result =
            pipeline.processCandidate(
                ScannerCandidate(
                    rawValue = "VG-101",
                    capturedAtEpochMillis = 55L
                )
            )

        assertThat(result).isEqualTo(ScannerResult.ReplaySuppressed(ScannerCandidate("VG-101", 55L)))
    }

    private class RecordingQueueCapturedScanUseCase : QueueCapturedScanUseCase {
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
            this.ticketCode = ticketCode
            this.direction = direction
            this.operatorName = operatorName
            this.entranceName = entranceName
            return QueueCreationResult.ReplaySuppressed
        }
    }
}
