package za.co.voelgoed.fastcheck.feature.scanning

import com.google.common.truth.Truth.assertThat
import kotlinx.coroutines.test.runTest
import org.junit.Test
import za.co.voelgoed.fastcheck.core.network.PhoenixMobileApi
import za.co.voelgoed.fastcheck.data.remote.PhoenixMobileRemoteDataSource
import za.co.voelgoed.fastcheck.data.repository.MobileScanRepository
import za.co.voelgoed.fastcheck.domain.model.QueueCreationResult
import za.co.voelgoed.fastcheck.domain.model.ScanDirection
import za.co.voelgoed.fastcheck.domain.usecase.QueueCapturedScanUseCase
import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerCaptureDefaults
import za.co.voelgoed.fastcheck.feature.scanning.usecase.ScanCapturePipeline

class ScanCapturePipelineTest {
    @Test
    fun handsDecodedValueToLocalQueueWithScannerDefaults() = runTest {
        val fakeUseCase = RecordingQueueCapturedScanUseCase()
        val pipeline = ScanCapturePipeline(fakeUseCase)

        pipeline.onDecoded("VG-101")

        assertThat(fakeUseCase.ticketCode).isEqualTo("VG-101")
        assertThat(fakeUseCase.direction).isEqualTo(ScanDirection.IN)
        assertThat(fakeUseCase.operatorName).isEqualTo(ScannerCaptureDefaults.operatorName)
        assertThat(fakeUseCase.entranceName).isEqualTo(ScannerCaptureDefaults.entranceName)
    }

    @Test
    fun doesNotExposeDirectNetworkDependenciesAtAnalyzerBoundary() {
        val constructorParameterTypes =
            ScanCapturePipeline::class.java.declaredConstructors.single().parameterTypes.toList()

        assertThat(constructorParameterTypes).containsExactly(QueueCapturedScanUseCase::class.java)
        assertThat(constructorParameterTypes).doesNotContain(PhoenixMobileApi::class.java)
        assertThat(constructorParameterTypes).doesNotContain(PhoenixMobileRemoteDataSource::class.java)
        assertThat(constructorParameterTypes).doesNotContain(MobileScanRepository::class.java)
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
