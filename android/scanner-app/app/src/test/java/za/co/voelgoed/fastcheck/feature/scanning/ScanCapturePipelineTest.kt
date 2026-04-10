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
import za.co.voelgoed.fastcheck.domain.model.LocalAdmissionDecision
import za.co.voelgoed.fastcheck.domain.model.LocalAdmissionRejectReason
import za.co.voelgoed.fastcheck.domain.model.ScanDirection
import za.co.voelgoed.fastcheck.domain.usecase.AdmitScanUseCase
import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerCaptureDefaults
import za.co.voelgoed.fastcheck.feature.scanning.usecase.CaptureHandoffResult
import za.co.voelgoed.fastcheck.feature.scanning.usecase.ScanCapturePipeline

class ScanCapturePipelineTest {
    @Test
    fun handsDecodedValueToLocalQueueWithScannerDefaults() = runTest {
        val fakeUseCase = RecordingAdmitScanUseCase()
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

        assertThat(constructorParameterTypes).contains(AdmitScanUseCase::class.java)
        assertThat(constructorParameterTypes).doesNotContain(PhoenixMobileApi::class.java)
        assertThat(constructorParameterTypes).doesNotContain(PhoenixMobileRemoteDataSource::class.java)
        assertThat(constructorParameterTypes).doesNotContain(MobileScanRepository::class.java)
    }

    @Test
    fun firstCaptureAccepted_secondSameCodeWithinWindowSuppressed() = runTest {
        val fakeUseCase = RecordingAdmitScanUseCase()
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
        assertThat(first)
            .isEqualTo(
                CaptureHandoffResult.Accepted(
                    attendeeId = 101L,
                    displayName = "Jane Queue",
                    ticketCode = "CODE-A",
                    idempotencyKey = "idem-accepted",
                    scannedAt = "2026-04-06T10:00:00Z"
                )
            )
        assertThat(second).isEqualTo(CaptureHandoffResult.SuppressedByCooldown)
    }

    @Test
    fun differentCodeWithinWindowIsAcceptedImmediately() = runTest {
        val fakeUseCase = RecordingAdmitScanUseCase()
        var now = 5_000L
        val pipeline = ScanCapturePipeline(fakeUseCase) { now }

        val firstResult = async(start = CoroutineStart.UNDISPATCHED) { pipeline.handoffResults.first() }
        pipeline.onDecoded("CODE-A")
        val first = firstResult.await()

        now += 500L
        val secondResult = async(start = CoroutineStart.UNDISPATCHED) { pipeline.handoffResults.first() }
        pipeline.onDecoded("CODE-B")
        val second = secondResult.await()

        assertThat(fakeUseCase.enqueueCallCount).isEqualTo(2)
        assertThat(first)
            .isEqualTo(
                CaptureHandoffResult.Accepted(
                    attendeeId = 101L,
                    displayName = "Jane Queue",
                    ticketCode = "CODE-A",
                    idempotencyKey = "idem-accepted",
                    scannedAt = "2026-04-06T10:00:00Z"
                )
            )
        assertThat(second)
            .isEqualTo(
                CaptureHandoffResult.Accepted(
                    attendeeId = 101L,
                    displayName = "Jane Queue",
                    ticketCode = "CODE-B",
                    idempotencyKey = "idem-accepted",
                    scannedAt = "2026-04-06T10:00:00Z"
                )
            )
    }

    @Test
    fun sameCodeAfterSuppressionWindowIsAcceptedAgain() = runTest {
        val fakeUseCase = RecordingAdmitScanUseCase()
        var now = 10_000L
        val pipeline = ScanCapturePipeline(fakeUseCase) { now }

        val firstResult = async(start = CoroutineStart.UNDISPATCHED) { pipeline.handoffResults.first() }
        pipeline.onDecoded("CODE-A")
        val first = firstResult.await()

        now += 10_100L
        val secondResult = async(start = CoroutineStart.UNDISPATCHED) { pipeline.handoffResults.first() }
        pipeline.onDecoded("CODE-A")
        val second = secondResult.await()

        assertThat(fakeUseCase.enqueueCallCount).isEqualTo(2)
        assertThat(first)
            .isEqualTo(
                CaptureHandoffResult.Accepted(
                    attendeeId = 101L,
                    displayName = "Jane Queue",
                    ticketCode = "CODE-A",
                    idempotencyKey = "idem-accepted",
                    scannedAt = "2026-04-06T10:00:00Z"
                )
            )
        assertThat(second)
            .isEqualTo(
                CaptureHandoffResult.Accepted(
                    attendeeId = 101L,
                    displayName = "Jane Queue",
                    ticketCode = "CODE-A",
                    idempotencyKey = "idem-accepted",
                    scannedAt = "2026-04-06T10:00:00Z"
                )
            )
    }

    @Test
    fun sameCodeIsSuppressedEvenAfterDifferentCodeInBetween() = runTest {
        val fakeUseCase = RecordingAdmitScanUseCase()
        var now = 20_000L
        val pipeline = ScanCapturePipeline(fakeUseCase) { now }

        pipeline.onDecoded("CODE-A")
        now += 500L
        pipeline.onDecoded("CODE-B")
        now += 500L
        val thirdResult = async(start = CoroutineStart.UNDISPATCHED) { pipeline.handoffResults.first() }
        pipeline.onDecoded("CODE-A")
        val third = thirdResult.await()

        assertThat(fakeUseCase.enqueueCallCount).isEqualTo(2)
        assertThat(third).isEqualTo(CaptureHandoffResult.SuppressedByCooldown)
    }

    @Test
    fun rejectedTicketAlsoStartsSameTicketSuppressionWindow() = runTest {
        val fakeUseCase =
            RecordingAdmitScanUseCase().apply {
                decisionsByTicketCode["BLOCKED"] =
                    LocalAdmissionDecision.Rejected(
                        reason = LocalAdmissionRejectReason.AlreadyInside,
                        ticketCode = "BLOCKED",
                        displayName = "Blocked Guest",
                        displayMessage = "Already inside"
                    )
            }
        var now = 30_000L
        val pipeline = ScanCapturePipeline(fakeUseCase) { now }

        val firstResult = async(start = CoroutineStart.UNDISPATCHED) { pipeline.handoffResults.first() }
        pipeline.onDecoded("BLOCKED")
        firstResult.await()
        now += 300L
        val secondResult = async(start = CoroutineStart.UNDISPATCHED) { pipeline.handoffResults.first() }
        pipeline.onDecoded("BLOCKED")
        val second = secondResult.await()

        assertThat(fakeUseCase.enqueueCallCount).isEqualTo(1)
        assertThat(second).isEqualTo(CaptureHandoffResult.SuppressedByCooldown)
    }

    @Test
    fun operationalFailureDoesNotStartSameTicketSuppressionWindow() = runTest {
        val fakeUseCase =
            RecordingAdmitScanUseCase().apply {
                decisionsByTicketCode["BROKEN"] =
                    LocalAdmissionDecision.OperationalFailure("Queue temporarily unavailable")
            }
        var now = 40_000L
        val pipeline = ScanCapturePipeline(fakeUseCase) { now }

        pipeline.onDecoded("BROKEN")
        now += 300L
        pipeline.onDecoded("BROKEN")

        assertThat(fakeUseCase.enqueueCallCount).isEqualTo(2)
    }

    private class RecordingAdmitScanUseCase : AdmitScanUseCase {
        var enqueueCallCount: Int = 0
        var ticketCode: String? = null
        var direction: ScanDirection? = null
        var operatorName: String? = null
        var entranceName: String? = null
        val decisionsByTicketCode: MutableMap<String, LocalAdmissionDecision> = mutableMapOf()

        override suspend fun admit(
            ticketCode: String,
            direction: ScanDirection,
            operatorName: String,
            entranceName: String
        ): LocalAdmissionDecision {
            enqueueCallCount += 1
            this.ticketCode = ticketCode
            this.direction = direction
            this.operatorName = operatorName
            this.entranceName = entranceName
            decisionsByTicketCode[ticketCode]?.let { return it }
            return LocalAdmissionDecision.Accepted(
                attendeeId = 101L,
                displayName = "Jane Queue",
                ticketCode = ticketCode.trim(),
                idempotencyKey = "idem-accepted",
                scannedAt = "2026-04-06T10:00:00Z",
                localQueueId = 1L
            )
        }
    }
}
